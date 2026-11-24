#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
results="$root/data/results"
tmp="$root/data/tmp"
mkdir -p "$results" "$tmp"
export PGDATABASE=pg19_monitoring

psql -X -v ON_ERROR_STOP=1 -c "DROP TABLE IF EXISTS lab.progress_lab; CREATE TABLE lab.progress_lab (id integer PRIMARY KEY, payload text) WITH (autovacuum_enabled = false); INSERT INTO lab.progress_lab SELECT i, repeat('p', 100) FROM generate_series(1, 50000) AS i; UPDATE lab.progress_lab SET payload = repeat('P', 100) WHERE id % 2 = 0; SELECT pg_stat_force_next_flush();" > "$tmp/progress-setup.log"

psql -X -v ON_ERROR_STOP=1 -c "SET vacuum_cost_delay = 20" -c "SET vacuum_cost_limit = 1" -c "VACUUM lab.progress_lab" > "$tmp/manual-vacuum.log" 2>&1 &
manual=$!
found=false
for _ in $(seq 1 200); do
    psql -X --csv -c "SELECT pid, relid::regclass AS relid, phase, started_by, mode, heap_blks_total, heap_blks_scanned FROM pg_stat_progress_vacuum WHERE relid = 'lab.progress_lab'::regclass" > "$tmp/progress.csv"
    if (( $(wc -l < "$tmp/progress.csv") > 1 )); then
        mv "$tmp/progress.csv" "$results/progress-manual-vacuum.csv"
        found=true
        break
    fi
    sleep 0.1
done
wait "$manual"
[[ $found == true ]]

psql -X -v ON_ERROR_STOP=1 -c "SET vacuum_cost_delay = 20" -c "SET vacuum_cost_limit = 1" -c "ANALYZE lab.progress_lab" > "$tmp/manual-analyze.log" 2>&1 &
manual=$!
found=false
for _ in $(seq 1 200); do
    psql -X --csv -c "SELECT pid, relid::regclass AS relid, phase, started_by, sample_blks_total, sample_blks_scanned FROM pg_stat_progress_analyze WHERE relid = 'lab.progress_lab'::regclass" > "$tmp/progress.csv"
    if (( $(wc -l < "$tmp/progress.csv") > 1 )); then
        mv "$tmp/progress.csv" "$results/progress-manual-analyze.csv"
        found=true
        break
    fi
    sleep 0.1
done
wait "$manual"
[[ $found == true ]]

psql -X -v ON_ERROR_STOP=1 -c "UPDATE lab.progress_lab SET payload = repeat('a', 100) WHERE id % 2 = 0; ALTER TABLE lab.progress_lab SET (autovacuum_enabled = true, autovacuum_vacuum_threshold = 1, autovacuum_vacuum_scale_factor = 0, autovacuum_analyze_threshold = 1000000, autovacuum_vacuum_cost_delay = 20, autovacuum_vacuum_cost_limit = 1); SELECT pg_stat_force_next_flush();" > "$tmp/auto-vacuum-setup.log"
found=false
for _ in $(seq 1 400); do
    psql -X --csv -c "SELECT pid, relid::regclass AS relid, phase, started_by, mode, heap_blks_total, heap_blks_scanned FROM pg_stat_progress_vacuum WHERE relid = 'lab.progress_lab'::regclass" > "$tmp/progress.csv"
    if (( $(wc -l < "$tmp/progress.csv") > 1 )); then
        mv "$tmp/progress.csv" "$results/progress-auto-vacuum.csv"
        found=true
        break
    fi
    sleep 0.2
done
[[ $found == true ]]
