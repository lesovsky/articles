#!/usr/bin/env bash
# Re-capture the strace evidence behind RESULTS section 0: under io_method = sync
# the read stream still prefetches through posix_fadvise, so plain "sync" is NOT
# pre-AIO behaviour. Session 2 reported the counts but kept no artifact.
set -euo pipefail
OUT=/bench/results/strace
mkdir -p "$OUT"
PGVER=19; CONF=/etc/postgresql/$PGVER/main/conf.d/99-aio-test.conf

cell() {
  local name=$1 method=$2 eic=$3
  printf 'io_method = %s\neffective_io_concurrency = %s\n' "$method" "$eic" | sudo tee "$CONF" >/dev/null
  sudo pg_ctlcluster $PGVER main stop
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  sudo pg_ctlcluster $PGVER main start
  for _ in $(seq 1 60); do psql -X -q -d bench -c 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done

  # long-lived session, so strace can attach to its backend before the query runs
  local fifo; fifo=$(mktemp -u); mkfifo "$fifo"
  psql -X -q -d bench -f "$fifo" > /dev/null 2>&1 &
  local psqlpid=$!
  exec 9>"$fifo"
  echo "SELECT pg_backend_pid();" >&9
  sleep 2
  local bp; bp=$(psql -X -t -A -d bench -c \
    "SELECT pid FROM pg_stat_activity WHERE backend_type='client backend' AND pid <> pg_backend_pid() ORDER BY backend_start DESC LIMIT 1")
  sudo strace -f -c -p "$bp" -o "$OUT/$name.txt" &
  local st=$!
  sleep 1
  echo "SELECT sum(id) FROM bench WHERE sel_key >= 5000 AND sel_key < 6000;" >&9
  sleep 1
  # wait for the query to finish
  while [ "$(psql -X -t -A -d bench -c "SELECT count(*) FROM pg_stat_activity WHERE pid=$bp AND state='active'")" = "1" ]; do sleep 1; done
  sudo kill -INT "$st" 2>/dev/null || true; wait "$st" 2>/dev/null || true
  exec 9>&-; wait "$psqlpid" 2>/dev/null || true; rm -f "$fifo"
  echo "--- $name ($method, eic=$eic) ---"
  grep -E "fadvise64|pread64|io_uring_enter|epoll_wait| read$|  read" "$OUT/$name.txt" || true
}

cell sync_eic16   sync     16
cell sync_eic0    sync     0
cell worker_eic16 worker   16
cell uring_eic16  io_uring 16
echo "=== STRACE ГОТОВ ==="
