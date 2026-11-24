#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
results="$root/data/results"
tmp="$root/data/tmp"
mkdir -p "$results" "$tmp"
export PGDATABASE=pg19_monitoring

psql -X --csv -c "SELECT * FROM pg_stat_lock ORDER BY locktype" > "$results/lock-before.csv"
psql -X -v ON_ERROR_STOP=1 -c "BEGIN; UPDATE lab.lock_lab SET payload = 'holder' WHERE id = 1; SELECT pg_sleep(4); COMMIT;" > "$tmp/lock-holder.log" 2>&1 &
holder=$!
sleep 1
for i in 1 2 3; do
    psql -X -v ON_ERROR_STOP=1 -c "UPDATE lab.lock_lab SET payload = 'waiter-$i' WHERE id = 1" > "$tmp/lock-waiter-$i.log" 2>&1 &
done
sleep 1
psql -X --csv -c "SELECT pid, wait_event_type, wait_event, state, query FROM pg_stat_activity WHERE datname = current_database() AND query LIKE '%lab.lock_lab%' ORDER BY pid" > "$results/lock-activity.csv"
wait "$holder"
wait
psql -X --csv -c "SELECT * FROM pg_stat_lock ORDER BY locktype" > "$results/lock-after.csv"

psql -X --csv -c "SELECT * FROM pg_get_multixact_stats()" > "$results/multixact-before.csv"
psql -X -v ON_ERROR_STOP=1 -c "BEGIN; SELECT * FROM lab.multixact_lab WHERE id = 1 FOR SHARE; SELECT pg_sleep(3); COMMIT;" > "$tmp/multixact-1.log" 2>&1 &
first=$!
sleep 1
psql -X -v ON_ERROR_STOP=1 -c "BEGIN; SELECT * FROM lab.multixact_lab WHERE id = 1 FOR SHARE; SELECT pg_sleep(2); COMMIT;" > "$tmp/multixact-2.log" 2>&1 &
second=$!
wait "$first" "$second"
psql -X --csv -c "SELECT * FROM pg_get_multixact_stats()" > "$results/multixact-after.csv"
