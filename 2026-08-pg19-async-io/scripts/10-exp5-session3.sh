#!/usr/bin/env bash
# Session 3 top-up runs — everything the article needs that session 2 left open.
#
# Part A (experiment 5): the whole headline table in ONE series, so every ratio
# printed in the article is computed within a single run with a single
# aggregation. Session 2 spread these cells across experiments 1 and 3, which
# mixed median-of-3 with min-of-2.
#
#   PG 17 defaults : sync,     effective_io_concurrency = 1,  maintenance_io_concurrency = 10
#   PG 19 defaults : worker,   effective_io_concurrency = 16, maintenance_io_concurrency = 16
#   tuned 19       : io_uring, effective_io_concurrency = 64, maintenance_io_concurrency = 16
#
# maintenance_io_concurrency matters because VACUUM reads through it, not
# through effective_io_concurrency, and its PG 17 default is 10 — not 1.
#
# Part B (experiment 6): bitmap heap scan against a warm page cache. The working
# set is ~460 MB and fits in 4 GB of RAM, so iterations 2 and 3 are warm. Seq
# scan and VACUUM are excluded: 33 GB never goes warm on this box.
#
# Part C: fio randread re-measured on a 12 GB file. Session 1 took the QD1
# latency and the QD1->QD16 scaling off an 8 GB file that was later shown to
# understate sequential throughput.
set -euo pipefail

RESULTS=${RESULTS:-/bench/results}
HERE=/bench/scripts

# ----------------------------------------------------------------- part A
export EXP=5 ITERATIONS=3 WIDTH=1000

pg17="$(printf 'effective_io_concurrency = 1\nmaintenance_io_concurrency = 10')"
pg19="$(printf 'effective_io_concurrency = 16\nmaintenance_io_concurrency = 16')"
tuned="$(printf 'effective_io_concurrency = 64\nmaintenance_io_concurrency = 16')"

for w in bitmap seqscan vacuum; do
  echo "=== e5 $w pg17default (sync, eic=1, mio=10) ==="
  TAG="e5_${w}_pg17default" WORKLOAD=$w IO_METHOD=sync   GUCS="$pg17"  "$HERE/03-runner.sh"
  echo "=== e5 $w pg19default (worker, eic=16, mio=16) ==="
  TAG="e5_${w}_pg19default" WORKLOAD=$w IO_METHOD=worker GUCS="$pg19"  "$HERE/03-runner.sh"
  echo "=== e5 $w tuned (io_uring, eic=64, mio=16) ==="
  TAG="e5_${w}_tuned"       WORKLOAD=$w IO_METHOD=io_uring GUCS="$tuned" "$HERE/03-runner.sh"
done

# ----------------------------------------------------------------- part B
# Warm cache: one cold start, then the same query three times in a row.
PGVER=19; PGCLUSTER=main
CONF=/etc/postgresql/$PGVER/$PGCLUSTER/conf.d/99-aio-test.conf

warm_cell() {
  local tag=$1 method=$2 gucs=$3
  printf 'io_method = %s\n%s\n' "$method" "$gucs" | sudo tee "$CONF" >/dev/null
  sudo pg_ctlcluster $PGVER $PGCLUSTER stop
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
  sudo pg_ctlcluster $PGVER $PGCLUSTER start
  for _ in $(seq 1 60); do psql -X -q -d bench -c 'SELECT 1' >/dev/null 2>&1 && break; sleep 0.5; done

  local m eic cl t0 t1 sql
  m=$(psql -X -t -A -d bench -c 'SHOW io_method')
  eic=$(psql -X -t -A -d bench -c 'SHOW effective_io_concurrency')
  cl=$(psql -X -t -A -d bench -c 'SHOW io_combine_limit')
  sql="SELECT sum(id) FROM bench WHERE sel_key >= 5000 AND sel_key < 6000;"

  for iter in 1 2 3; do
    t0=$(date +%s%N)
    psql -X -q -d bench -c "$sql" >/dev/null
    t1=$(date +%s%N)
    echo "6,$tag,bitmap,$m,2,8,$eic,$cl,1,$iter,0,$(((t1 - t0) / 1000000))" >> "$RESULTS/results.csv"
  done
  echo "$tag: $(grep ",$tag,bitmap," "$RESULTS/results.csv" | cut -d, -f12 | tr '\n' ' ')ms (iter 1 холодная, 2-3 прогретые)"
}

echo "=== e6 warm cache ==="
warm_cell e6_warm_sync   sync   "$(printf 'effective_io_concurrency = 16')"
warm_cell e6_warm_worker worker "$(printf 'effective_io_concurrency = 16')"

# ----------------------------------------------------------------- part C
echo "=== fio randread на файле 12 GB ==="
FIOF=/bench/fio12.dat
for qd in 1 16; do
  fio --name=randread8k-qd$qd --filename=$FIOF --size=12G --bs=8k --rw=randread \
      --direct=1 --ioengine=libaio --iodepth=$qd --runtime=20 --time_based \
      --group_reporting --output-format=json \
      --output=/bench/out12-randread8k-qd$qd.json >/dev/null
  echo "qd$qd готов"
done
rm -f "$FIOF"

echo "=== ВСЁ ГОТОВО ==="
