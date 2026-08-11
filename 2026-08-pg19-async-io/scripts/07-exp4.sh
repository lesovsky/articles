#!/usr/bin/env bash
# Experiment 4 - observability. Not a benchmark: these are the artifacts a DBA
# would actually look at, captured once per io_method.
set -euo pipefail
OUT=${RESULTS:-/bench/results}/observ
mkdir -p "$OUT"
CONF=/etc/postgresql/19/main/conf.d/99-aio-test.conf
Q="SELECT sum(id) FROM bench WHERE sel_key >= 5000 AND sel_key < 6000"

cold() {
  sudo pg_ctlcluster 19 main stop
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  sudo pg_ctlcluster 19 main start
  for _ in $(seq 1 60); do psql -X -q -d bench -c 'SELECT 1' >/dev/null 2>&1 && return; sleep 0.5; done
}

for m in sync worker io_uring; do
  echo "io_method = $m" | sudo tee $CONF >/dev/null
  cold
  psql -X -q -d bench -c "SELECT pg_stat_reset_shared('io')" >/dev/null

  # pg_aios sampled while the query runs: in-flight operations, one row each
  ( for _ in $(seq 1 60); do
      psql -X -A -F',' -t -d bench -c \
        "SELECT clock_timestamp(), pid, state, operation, length, target, f_sync, f_buffered
         FROM pg_aios" 2>/dev/null
      sleep 0.05
    done ) > "$OUT/pg_aios_$m.csv" &
  aios=$!

  psql -X -d bench -o "$OUT/explain_$m.txt" -c "EXPLAIN (ANALYZE, BUFFERS, IO, COSTS OFF) $Q"
  kill $aios 2>/dev/null || true; wait $aios 2>/dev/null || true

  psql -X -d bench -o "$OUT/statio_$m.txt" -c \
    "SELECT backend_type, object, context, reads, read_bytes, round(read_time::numeric,1) AS read_ms,
            hits, evictions FROM pg_stat_io WHERE reads > 0 ORDER BY reads DESC"
  echo "--- $m done ---"
done

# The take-home message: a PG 18 config file will not start a PG 19 server.
echo "io_workers = 3" | sudo tee $CONF >/dev/null
sudo pg_ctlcluster 19 main restart 2>&1 | tee "$OUT/io_workers_error.txt" || true
sudo tail -5 /var/log/postgresql/postgresql-19-main.log | tee -a "$OUT/io_workers_error.txt"
echo "io_method = worker" | sudo tee $CONF >/dev/null
sudo pg_ctlcluster 19 main restart
