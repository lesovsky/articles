\set ON_ERROR_STOP off

DROP ROLE IF EXISTS pg19_plain, pg19_monitor_reader;
CREATE ROLE pg19_plain NOLOGIN;
CREATE ROLE pg19_monitor_reader NOLOGIN;
GRANT pg_monitor TO pg19_monitor_reader;

SET ROLE pg19_plain;
SELECT current_user AS role_name, count(*) AS rows_visible FROM pg_stat_lock;
SELECT current_user AS role_name, count(*) AS rows_visible FROM pg_stat_recovery;
SELECT current_user AS role_name, count(*) AS rows_visible FROM pg_stat_autovacuum_scores;
SELECT current_user AS role_name, count(*) AS rows_visible FROM pg_dsm_registry_allocations;
SELECT current_user AS role_name, * FROM pg_get_multixact_stats();
RESET ROLE;

SET ROLE pg19_monitor_reader;
SELECT current_user AS role_name, count(*) AS rows_visible FROM pg_stat_lock;
SELECT current_user AS role_name, count(*) AS rows_visible FROM pg_stat_recovery;
SELECT current_user AS role_name, count(*) AS rows_visible FROM pg_stat_autovacuum_scores;
SELECT current_user AS role_name, count(*) AS rows_visible FROM pg_dsm_registry_allocations;
SELECT current_user AS role_name, * FROM pg_get_multixact_stats();
RESET ROLE;

DROP ROLE pg19_plain, pg19_monitor_reader;
