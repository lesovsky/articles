#!/usr/bin/env bash
# One benchmark cell: apply GUCs, then repeat {cold restart -> workload} N times.
#
# Every iteration starts fully cold: PostgreSQL is stopped (dropping
# shared_buffers), the page cache is dropped, and only then is the server
# started again. Without the stop/start the 512 MB of shared_buffers would
# carry state across iterations.
#
# Configured through the environment:
#   TAG          run label, ends up in results.csv
#   EXP          experiment number (1..4)
#   WORKLOAD     bitmap | seqscan | vacuum
#   IO_METHOD    sync | worker | io_uring
#   GUCS         extra "key = value" lines, newline separated
#   WIDTH        bitmap: sel_key range width per session (1000 = 0.1% of rows)
#   CONCURRENCY  parallel client sessions (default 1)
#   ITERATIONS   repeats (default 3)
set -euo pipefail

PGVER=19; PGCLUSTER=main
CONF=/etc/postgresql/$PGVER/$PGCLUSTER/conf.d/99-aio-test.conf
RESULTS=${RESULTS:-/bench/results}
DB=${DB:-bench}
HERE=$(cd "$(dirname "$0")" && pwd)

TAG=${TAG:?}; EXP=${EXP:?}; WORKLOAD=${WORKLOAD:?}; IO_METHOD=${IO_METHOD:?}
GUCS=${GUCS:-}; WIDTH=${WIDTH:-1000}
CONCURRENCY=${CONCURRENCY:-1}; ITERATIONS=${ITERATIONS:-3}

mkdir -p "$RESULTS"/{waits,statio,explain}
[ -f "$RESULTS/results.csv" ] || echo \
"exp,tag,workload,io_method,io_min_workers,io_max_workers,eic,combine_limit,concurrency,iter,session,elapsed_ms" \
  > "$RESULTS/results.csv"

apply_conf() {
  printf 'io_method = %s\n%s\n' "$IO_METHOD" "$GUCS" | sudo tee "$CONF" >/dev/null
}

cold_restart() {
  sudo pg_ctlcluster $PGVER $PGCLUSTER stop
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  sudo pg_ctlcluster $PGVER $PGCLUSTER start
  # wait for readiness rather than sleeping a fixed amount
  for _ in $(seq 1 60); do psql -X -q -d "$DB" -c 'SELECT 1' >/dev/null 2>&1 && return; sleep 0.5; done
  echo "server did not come up" >&2; exit 1
}

# One client session. $1 = session index, $2 = file to write elapsed ms into.
session() {
  local idx=$1 out=$2 sql
  # sum(id) rather than count(*): id is not in the index, so the planner cannot
  # answer from an index-only scan over the 401 MB index and has to touch the
  # 33 GB heap - which is the I/O we are here to measure.
  case $WORKLOAD in
    bitmap)  sql="SELECT sum(id) FROM bench WHERE sel_key >= $((idx * WIDTH)) AND sel_key < $(((idx + 1) * WIDTH));" ;;
    seqscan) sql="SELECT sum(id) FROM bench;" ;;
    vacuum)  sql="VACUUM (DISABLE_PAGE_SKIPPING) bench;" ;;
  esac
  local t0 t1
  t0=$(date +%s%N)
  psql -X -q -d "$DB" -c "$sql" >/dev/null
  t1=$(date +%s%N)
  echo $(((t1 - t0) / 1000000)) > "$out"
}

guc() { psql -X -t -A -d "$DB" -c "SHOW $1"; }

apply_conf
for iter in $(seq 1 "$ITERATIONS"); do
  cold_restart
  # Snapshot the settings actually in effect, not the ones we asked for.
  METHOD=$(guc io_method)
  MINW=$(guc io_min_workers); MAXW=$(guc io_max_workers)
  EIC=$(guc effective_io_concurrency); CL=$(guc io_combine_limit)
  psql -X -q -d "$DB" -c "SELECT pg_stat_reset_shared('io')" >/dev/null

  waitfile="$RESULTS/waits/${TAG}_i${iter}.csv"
  "$HERE/02-wait-sampler.sh" "$waitfile" 0.01 900 &
  sampler=$!
  sleep 0.3

  tmp=$(mktemp -d); pids=()
  for s in $(seq 0 $((CONCURRENCY - 1))); do session "$s" "$tmp/$s" & pids+=($!); done
  wait "${pids[@]}"

  kill $sampler 2>/dev/null || true; wait $sampler 2>/dev/null || true

  for s in $(seq 0 $((CONCURRENCY - 1))); do
    echo "$EXP,$TAG,$WORKLOAD,$METHOD,$MINW,$MAXW,$EIC,$CL,$CONCURRENCY,$iter,$s,$(cat "$tmp/$s")" \
      >> "$RESULTS/results.csv"
  done
  rm -rf "$tmp"

  psql -X -q -d "$DB" -c "\copy (SELECT '$TAG' AS tag, $iter AS iter, * FROM pg_stat_io
     WHERE reads > 0 OR writes > 0) TO '$RESULTS/statio/${TAG}_i${iter}.csv' CSV HEADER"

  echo "$TAG iter $iter: $(grep ",$TAG,.*,$iter," "$RESULTS/results.csv" | cut -d, -f12 | tr '\n' ' ')ms"
done
