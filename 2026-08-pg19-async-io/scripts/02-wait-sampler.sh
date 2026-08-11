#!/usr/bin/env bash
# Poor man's wait event sampler: one long-lived psql session polling
# pg_stat_activity via \watch. PostgreSQL has no built-in cumulative wait
# sampler in 18 or 19, and an extension would be one more thing for the reader
# to install.
#
# Usage: 02-wait-sampler.sh OUTFILE [INTERVAL_S] [DURATION_S]
# Writes CSV: ts,pid,backend_type,state,wait_event_type,wait_event
# Terminate early with SIGTERM/SIGINT; partial output is still valid.
set -euo pipefail

OUT=$1
INTERVAL=${2:-0.01}
DURATION=${3:-600}
DB=${DB:-bench}
COUNT=$(awk -v d="$DURATION" -v i="$INTERVAL" 'BEGIN{printf "%d", d/i}')

# One connection is held open for the whole run; only the query repeats, so the
# sampler itself costs a fraction of a millisecond per sample.
#
# psql writes the file itself (-o) instead of the output going through a pipe:
# with a pipe this is a pipeline, exec cannot replace the shell, and the caller's
# kill hits the subshell while psql keeps running and holds the file open.
exec psql -X -q -A -F',' -t -o "$OUT" -d "$DB" <<SQL 2>/dev/null
SELECT clock_timestamp(),
       pid,
       coalesce(backend_type, '?'),
       coalesce(state, '-'),
       coalesce(wait_event_type, 'CPU'),
       coalesce(wait_event, 'CPU')
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
  AND (state = 'active' OR backend_type NOT IN ('client backend', 'autovacuum launcher'));
\watch i=$INTERVAL c=$COUNT
SQL
