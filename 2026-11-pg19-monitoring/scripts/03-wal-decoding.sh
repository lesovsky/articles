#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/data/results"
psql -X -d pg19_monitoring -v ON_ERROR_STOP=1 -f "$root/scripts/03-wal-decoding.sql" > "$root/data/results/wal-decoding.log"
