#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/data/results"
"$root/scripts/01-setup.sh" > "$root/data/setup.log"
psql -X -d pg19_monitoring -v ON_ERROR_STOP=1 -f "$root/scripts/04-autovacuum.sql" > "$root/data/results/autovacuum-scores.log"
