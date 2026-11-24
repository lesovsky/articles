#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
db=pg19_monitoring

if ! psql -X -d postgres -Atqc "SELECT EXISTS (SELECT FROM pg_database WHERE datname = '$db')" | grep -qx t; then
    createdb "$db"
fi
psql -X -d "$db" -v ON_ERROR_STOP=1 -f "$root/scripts/01-setup.sql"
