\set ON_ERROR_STOP on

CREATE TEMP TABLE wal_samples (
    phase text,
    wal_records bigint,
    wal_fpi bigint,
    wal_bytes numeric,
    wal_fpi_bytes numeric
);
SELECT pg_stat_force_next_flush();
SELECT pg_stat_clear_snapshot();

INSERT INTO wal_samples
SELECT 'first_before', wal_records, wal_fpi, wal_bytes, wal_fpi_bytes
FROM pg_stat_get_backend_wal(pg_backend_pid());

CHECKPOINT;
UPDATE lab.wal_lab SET payload = repeat('a', 200) WHERE id = 1;
SELECT pg_stat_force_next_flush();
SELECT pg_stat_clear_snapshot();

INSERT INTO wal_samples
SELECT 'first_after', wal_records, wal_fpi, wal_bytes, wal_fpi_bytes
FROM pg_stat_get_backend_wal(pg_backend_pid());

SELECT 'first update after checkpoint' AS phase,
    a.wal_records - b.wal_records AS wal_records,
    a.wal_fpi - b.wal_fpi AS wal_fpi,
    a.wal_bytes - b.wal_bytes AS wal_bytes,
    a.wal_fpi_bytes - b.wal_fpi_bytes AS wal_fpi_bytes
FROM wal_samples b, wal_samples a
WHERE b.phase = 'first_before' AND a.phase = 'first_after';

INSERT INTO wal_samples
SELECT 'second_before', wal_records, wal_fpi, wal_bytes, wal_fpi_bytes
FROM pg_stat_get_backend_wal(pg_backend_pid());

UPDATE lab.wal_lab SET payload = repeat('b', 200) WHERE id = 1;
SELECT pg_stat_force_next_flush();
SELECT pg_stat_clear_snapshot();

INSERT INTO wal_samples
SELECT 'second_after', wal_records, wal_fpi, wal_bytes, wal_fpi_bytes
FROM pg_stat_get_backend_wal(pg_backend_pid());

SELECT 'second update without checkpoint' AS phase,
    a.wal_records - b.wal_records AS wal_records,
    a.wal_fpi - b.wal_fpi AS wal_fpi,
    a.wal_bytes - b.wal_bytes AS wal_bytes,
    a.wal_fpi_bytes - b.wal_fpi_bytes AS wal_fpi_bytes
FROM wal_samples b, wal_samples a
WHERE b.phase = 'second_before' AND a.phase = 'second_after';

SELECT wal_fpi_bytes, wal_bytes, stats_reset
FROM pg_stat_wal;

SELECT 'before logical slot' AS phase, current_setting('wal_level') AS wal_level,
    current_setting('effective_wal_level') AS effective_wal_level;

SELECT pg_drop_replication_slot('lab_decode')
WHERE EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = 'lab_decode');
SELECT pg_create_logical_replication_slot('lab_decode', 'test_decoding');

SELECT 'after logical slot' AS phase, current_setting('wal_level') AS wal_level,
    current_setting('effective_wal_level') AS effective_wal_level;

SET logical_decoding_work_mem = '1MB';
UPDATE lab.decode_lab SET payload = repeat('D', 400);

SELECT count(*) AS decoded_changes
FROM pg_logical_slot_get_changes('lab_decode', NULL, NULL);

SELECT pg_stat_clear_snapshot();
SELECT slot_name, spill_txns, spill_count, spill_bytes, stream_txns,
    mem_exceeded_count, total_txns, total_bytes
FROM pg_stat_replication_slots WHERE slot_name = 'lab_decode';

SELECT pg_drop_replication_slot('lab_decode');
CHECKPOINT;
SELECT 'after slot drop and checkpoint' AS phase,
    current_setting('wal_level') AS wal_level,
    current_setting('effective_wal_level') AS effective_wal_level;
