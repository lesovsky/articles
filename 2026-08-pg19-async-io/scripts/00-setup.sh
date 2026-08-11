#!/usr/bin/env bash
# One-time stand preparation: base postgresql.conf for the experiments,
# a superuser role for the OS user, and the bench database.
set -euo pipefail

PGVER=19
PGCLUSTER=main
CONFD=/etc/postgresql/$PGVER/$PGCLUSTER/conf.d
OSUSER=$(id -un)

sudo tee $CONFD/10-bench-base.conf >/dev/null <<'EOF'
# --- fixed across all runs; the experiment knobs live in 99-aio-test.conf ---
shared_buffers = 512MB
max_connections = 100
work_mem = 16MB
maintenance_work_mem = 512MB

# Parallelism would mix its own prefetch effect into the AIO measurements.
max_parallel_workers_per_gather = 0

# Autovacuum must not touch the bench table mid-run.
autovacuum = off

# Needed for pg_stat_io timing columns.
track_io_timing = on

# The dataset is UNLOGGED, so WAL settings barely matter; keep checkpoints
# out of the way anyway.
checkpoint_timeout = 30min
max_wal_size = 4GB
EOF

sudo pg_ctlcluster $PGVER $PGCLUSTER restart
sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 <<EOF
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$OSUSER') THEN
    CREATE ROLE $OSUSER LOGIN SUPERUSER;
  END IF;
END \$\$;
EOF

echo "--- effective settings ---"
psql -X -d postgres -c "SELECT name, setting, unit, source FROM pg_settings
  WHERE name IN ('shared_buffers','io_method','io_min_workers','io_max_workers',
                 'io_combine_limit','io_max_combine_limit','io_max_concurrency',
                 'effective_io_concurrency','maintenance_io_concurrency',
                 'max_parallel_workers_per_gather','track_io_timing')
  ORDER BY name;"
