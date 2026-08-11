#!/usr/bin/env bash
# Experiment 2 - the main chart: a fixed io worker pool against an adaptive one,
# swept over concurrent reading sessions.
#
# fixed3   emulates the PG 18 configuration (io_workers = 3)
# adaptive is the PG 19 default (2..8)
# fixed8   is the control: if adaptive wins only because it ends up with more
#          workers, fixed8 must match it; if not, the adaptivity itself matters
# uring    is the second control: no worker pool is involved at all
set -euo pipefail
export EXP=2 ITERATIONS=${ITERATIONS:-3} WORKLOAD=bitmap WIDTH=${WIDTH:-1000}

declare -A CFG=(
  [fixed3]='io_min_workers = 3\nio_max_workers = 3'
  [adaptive]='io_min_workers = 2\nio_max_workers = 8'
  [fixed8]='io_min_workers = 8\nio_max_workers = 8'
  [uring]=''
  [sync]=''   # fadvise path: the thing the worker pool has to beat
)

for name in fixed3 adaptive fixed8 uring sync; do
  for c in 1 2 4 8 16; do
    echo "=== e2 $name c=$c ==="
    case $name in uring) method=io_uring ;; sync) method=sync ;; *) method=worker ;; esac
    TAG="e2_${name}_c${c}" IO_METHOD=$method CONCURRENCY=$c \
      GUCS="$(printf "${CFG[$name]}")" /bench/scripts/03-runner.sh
  done
done
