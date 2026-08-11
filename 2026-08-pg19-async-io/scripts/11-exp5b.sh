#!/usr/bin/env bash
# Experiment 5b — the true QD1 baseline inside the same series as experiment 5.
#
# Needed because eic = 1 is NOT a faithful proxy of PostgreSQL 17 for seq scan
# and VACUUM: in 17 effective_io_concurrency "only affects bitmap heap scans",
# so those two workloads ran with no prefetch queue at all. On 19 a depth-1
# queue turns out to cost real time, so eic = 1 would overstate the upgrade.
set -euo pipefail
export EXP=5 ITERATIONS=3 WIDTH=1000
qd1="$(printf 'effective_io_concurrency = 0\nmaintenance_io_concurrency = 0')"
for w in bitmap seqscan vacuum; do
  echo "=== e5 $w qd1 (sync, eic=0, mio=0) ==="
  TAG="e5_${w}_qd1" WORKLOAD=$w IO_METHOD=sync GUCS="$qd1" /bench/scripts/03-runner.sh
done
echo "=== ВСЁ ГОТОВО 5B ==="
