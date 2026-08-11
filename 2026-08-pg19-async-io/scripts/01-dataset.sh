#!/usr/bin/env bash
# Build the benchmark dataset: ~TARGET_GB of heap + a btree index on a column
# that is uncorrelated with physical row order (so bitmap heap scan reads
# pages sparsely, which is the whole point of the experiment).
set -euo pipefail

DB=${DB:-bench}
TARGET_GB=${TARGET_GB:-30}
CHUNK_ROWS=${CHUNK_ROWS:-5000000}
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d $DB"

psql -X -q -v ON_ERROR_STOP=1 -d postgres \
  -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"

$PSQL <<'SQL'
-- UNLOGGED on purpose: the dataset is read-only test data, regenerated from
-- scratch on demand. Durability buys nothing here and would double write I/O.
CREATE UNLOGGED TABLE bench (
    id      bigint NOT NULL,
    sel_key int    NOT NULL,   -- uniform in [0, 1e6), independent of physical order
    payload bytea  NOT NULL    -- 512 random bytes: fixes row width and leaves
);                             -- nothing for storage-level compression to find

-- 4096 pre-generated random payloads. Generating entropy per row would make
-- the loader CPU-bound; picking from a small pool keeps it I/O-bound while the
-- repeat period (4096 rows ~ 2 MB of heap) stays far outside any compressor
-- window a storage layer might use.
CREATE UNLOGGED TABLE pool AS
SELECT g AS k,
       decode(string_agg(md5(random()::text), ''), 'hex') AS payload
FROM generate_series(0, 4095) g, generate_series(1, 32) m
GROUP BY g;
ALTER TABLE pool ADD PRIMARY KEY (k);

ALTER TABLE bench SET (autovacuum_enabled = off);
SQL

load_chunk() {  # $1 = first id
  $PSQL -c "INSERT INTO bench (id, sel_key, payload)
            SELECT g, (random() * 1000000)::int, p.payload
            FROM generate_series($1, $1 + $CHUNK_ROWS - 1) g
            JOIN pool p ON p.k = g % 4096;"
}

size_bytes() { $PSQL -t -A -c "SELECT pg_relation_size('bench');"; }

target_bytes=$((TARGET_GB * 1024 * 1024 * 1024))
next_id=1

echo "$(date +%T) loading first chunk to measure row width..."
load_chunk $next_id
next_id=$((next_id + CHUNK_ROWS))
bytes=$(size_bytes)
per_row=$(( bytes / CHUNK_ROWS ))
total_rows=$(( target_bytes / per_row ))
chunks=$(( (total_rows - CHUNK_ROWS + CHUNK_ROWS - 1) / CHUNK_ROWS ))
echo "row width on disk: ${per_row} B -> ${total_rows} rows total, ${chunks} more chunks"

for ((i = 1; i <= chunks; i++)); do
  load_chunk $next_id
  next_id=$((next_id + CHUNK_ROWS))
  echo "$(date +%T) chunk $i/$chunks done, heap $(( $(size_bytes) / 1024 / 1024 / 1024 )) GB"
done

echo "$(date +%T) building index..."
$PSQL -c "CREATE INDEX bench_sel_key_idx ON bench (sel_key);"
echo "$(date +%T) vacuum analyze..."
$PSQL -c "VACUUM (ANALYZE, FREEZE) bench;"

$PSQL <<'SQL'
\pset border 2
SELECT pg_size_pretty(pg_relation_size('bench'))            AS heap,
       pg_size_pretty(pg_relation_size('bench_sel_key_idx')) AS idx,
       (SELECT count(*) FROM bench)                          AS rows,
       (pg_relation_size('bench') / 8192)                    AS heap_pages,
       round((SELECT count(*) FROM bench)::numeric
             / (pg_relation_size('bench') / 8192), 1)        AS rows_per_page;
-- correlation must be ~0: that is what makes the bitmap scan read sparsely
SELECT attname, n_distinct, correlation
FROM pg_stats WHERE tablename = 'bench' AND attname = 'sel_key';
SQL
