#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
major=$(psql -X -Atqc "SELECT current_setting('server_version_num')::int / 10000")
out=${1:-"$root/data/inventory/pg$major"}

if [[ -e $out ]]; then
    echo "Inventory already exists: $out" >&2
    exit 1
fi
mkdir -p "$(dirname -- "$out")"
tmp=$(mktemp -d "$(dirname -- "$out")/.inventory.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

psql -X -v ON_ERROR_STOP=1 --csv -c "SELECT version() AS version, current_setting('server_version_num') AS server_version_num, current_setting('port') AS port" > "$tmp/server.csv"
psql -X -v ON_ERROR_STOP=1 --csv -c "SELECT n.nspname AS schema, c.relname AS view, a.attnum AS position, a.attname AS column, pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid WHERE n.nspname = 'pg_catalog' AND c.relkind = 'v' AND a.attnum > 0 AND NOT a.attisdropped ORDER BY c.relname, a.attnum" > "$tmp/catalog-view-columns.csv"
psql -X -v ON_ERROR_STOP=1 --csv -c "SELECT n.nspname AS schema, p.proname AS function, pg_catalog.pg_get_function_identity_arguments(p.oid) AS arguments, pg_catalog.pg_get_function_result(p.oid) AS result FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'pg_catalog' ORDER BY p.proname, arguments" > "$tmp/catalog-functions.csv"
psql -X -v ON_ERROR_STOP=1 --csv -c "SELECT name, category, context, vartype, unit, boot_val FROM pg_catalog.pg_settings ORDER BY name" > "$tmp/settings-metadata.csv"
psql -X -v ON_ERROR_STOP=1 --csv -c "SELECT type, name, description FROM pg_catalog.pg_wait_events ORDER BY type, name" > "$tmp/wait-events.csv"
psql -X -v ON_ERROR_STOP=1 --csv -c "SELECT e.extname, e.extversion, n.nspname AS schema FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace ORDER BY e.extname" > "$tmp/extensions.csv"

mv -- "$tmp" "$out"
trap - EXIT
