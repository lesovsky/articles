CREATE SCHEMA IF NOT EXISTS lab;

DROP TABLE IF EXISTS lab.lock_lab, lab.multixact_lab, lab.wal_lab, lab.decode_lab,
    lab.vacuum_hot, lab.vacuum_cold, lab.insert_only;

CREATE TABLE lab.lock_lab (id integer PRIMARY KEY, payload text);
INSERT INTO lab.lock_lab VALUES (1, 'initial');

CREATE TABLE lab.multixact_lab (id integer PRIMARY KEY, payload text);
INSERT INTO lab.multixact_lab VALUES (1, 'initial');

CREATE TABLE lab.wal_lab (id integer PRIMARY KEY, payload text);
INSERT INTO lab.wal_lab
SELECT i, repeat('x', 200) FROM generate_series(1, 1000) AS i;

CREATE TABLE lab.decode_lab (id integer PRIMARY KEY, payload text);
INSERT INTO lab.decode_lab
SELECT i, repeat('d', 200) FROM generate_series(1, 20000) AS i;

CREATE TABLE lab.vacuum_hot (id integer PRIMARY KEY, payload text)
WITH (autovacuum_enabled = false);
INSERT INTO lab.vacuum_hot
SELECT i, repeat('h', 100) FROM generate_series(1, 20000) AS i;

CREATE TABLE lab.vacuum_cold (id integer PRIMARY KEY, payload text)
WITH (autovacuum_enabled = false);
INSERT INTO lab.vacuum_cold
SELECT i, repeat('c', 100) FROM generate_series(1, 20000) AS i;

CREATE TABLE lab.insert_only (id integer PRIMARY KEY, payload text)
WITH (autovacuum_enabled = false);
INSERT INTO lab.insert_only
SELECT i, repeat('i', 100) FROM generate_series(1, 20000) AS i;

ANALYZE lab.lock_lab, lab.multixact_lab, lab.wal_lab, lab.decode_lab,
    lab.vacuum_hot, lab.vacuum_cold, lab.insert_only;
