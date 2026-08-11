#!/usr/bin/env bash
# Experiment 3 - how each io_method responds to queue depth.
#
# This became a main axis rather than a side sweep: sync reaches a plateau at
# eic~16 because the fadvise path cannot go deeper, while io_uring keeps
# scaling. Comparing methods at a single eic value would have been misleading.
# eic=0 is the true QD1 baseline (no prefetch at all).
set -euo pipefail
export EXP=3 WORKLOAD=bitmap WIDTH=${WIDTH:-1000} ITERATIONS=${ITERATIONS:-2}

for m in sync worker io_uring; do
  for e in 0 1 4 16 64 128; do
    echo "=== e3 $m eic=$e ==="
    TAG="e3_${m}_eic${e}" IO_METHOD=$m GUCS="effective_io_concurrency = $e" \
      /bench/scripts/03-runner.sh
  done
done

# io_combine_limit on seqscan, where adjacent blocks are the rule. Going past
# the 16-block default also needs io_max_combine_limit, which is start-time only.
export WORKLOAD=seqscan ITERATIONS=${SEQ_ITERATIONS:-2}
for m in sync worker; do
  for cl in 1 4 16 32; do
    echo "=== e3 $m combine_limit=$cl ==="
    TAG="e3_${m}_cl${cl}" IO_METHOD=$m \
      GUCS="$(printf 'io_max_combine_limit = 32\nio_combine_limit = %d' "$cl")" \
      /bench/scripts/03-runner.sh
  done
done
