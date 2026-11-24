\set ON_ERROR_STOP on

UPDATE lab.vacuum_hot SET payload = repeat('H', 100) WHERE id % 10 <> 0;
UPDATE lab.vacuum_hot SET payload = repeat('h', 100) WHERE id % 10 <> 0;
UPDATE lab.vacuum_cold SET payload = repeat('C', 100) WHERE id % 20 = 0;
INSERT INTO lab.insert_only
SELECT i, repeat('I', 100) FROM generate_series(20001, 40000) AS i;
SELECT pg_stat_force_next_flush();
SELECT pg_stat_clear_snapshot();

ALTER TABLE lab.vacuum_hot SET (autovacuum_enabled = true);
ALTER TABLE lab.vacuum_cold SET (autovacuum_enabled = true);
ALTER TABLE lab.insert_only SET (autovacuum_enabled = true);

SELECT pg_stat_clear_snapshot();
SELECT relname, n_live_tup, n_dead_tup, n_mod_since_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'lab'
    AND relname IN ('vacuum_hot', 'vacuum_cold', 'insert_only')
ORDER BY relname;

SELECT relname, round(score::numeric, 3) AS score,
    round(vacuum_score::numeric, 3) AS vacuum_score,
    round(vacuum_insert_score::numeric, 3) AS vacuum_insert_score,
    round(analyze_score::numeric, 3) AS analyze_score,
    do_vacuum, do_analyze
FROM pg_stat_autovacuum_scores
WHERE schemaname = 'lab'
    AND relname IN ('vacuum_hot', 'vacuum_cold', 'insert_only')
ORDER BY score DESC;

SELECT relname, stats_reset FROM pg_stat_user_tables
WHERE schemaname = 'lab' AND relname = 'vacuum_hot';
SELECT pg_stat_reset_single_table_counters('lab.vacuum_hot'::regclass);
SELECT pg_stat_clear_snapshot();
SELECT relname, stats_reset FROM pg_stat_user_tables
WHERE schemaname = 'lab' AND relname = 'vacuum_hot';
