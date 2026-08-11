#!/usr/bin/env bash
# Experiment 1 - the baseline picture across the three workloads.
#
# Four cells, not three: sync with eic=0 is the only honest "no prefetch at all"
# baseline. Plain sync is the posix_fadvise path, not pre-AIO behaviour.
set -euo pipefail
export EXP=1 ITERATIONS=${ITERATIONS:-3} WIDTH=${WIDTH:-1000}

for w in bitmap seqscan vacuum; do
  echo "=== e1 $w qd1 (sync, eic=0) ==="
  TAG="e1_${w}_qd1" WORKLOAD=$w IO_METHOD=sync \
    GUCS="$(printf 'effective_io_concurrency = 0\nmaintenance_io_concurrency = 0')" \
    /bench/scripts/03-runner.sh
  for m in sync worker io_uring; do
    echo "=== e1 $w $m ==="
    TAG="e1_${w}_${m}" WORKLOAD=$w IO_METHOD=$m GUCS="" /bench/scripts/03-runner.sh
  done
done
