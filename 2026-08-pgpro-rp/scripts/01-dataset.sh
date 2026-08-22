#!/bin/bash
# Подготовка данных для экспериментов.
#
# Три датасета с разным назначением:
#   postgres.pgbench_accounts (13 GB при 8 GB RAM) — нагрузка соседа, упирающаяся
#                       в диск; для проверки осей ioread/iowrite;
#   postgres.t20 (2.5 GB, помещается в страничный кеш) — нагрузка соседа,
#                       упирающаяся в CPU, без примеси ввода-вывода;
#   база oltp (-s 100, 1.5 GB) — OLTP-нагрузка pgbench. Отдельная маленькая база
#                       нужна для стабильности: на датасете 13 GB при
#                       shared_buffers 1 GB пропускная способность скачет
#                       от 50 до 344 tps между прогонами из-за чекпойнтов,
#                       и на таком разбросе сравнивать конфигурации нельзя.
set -e

PSQL="sudo -u postgres psql"

echo "== pgbench -i -s 1000 (13 GB, примерно 15 минут на 4 vCPU) =="
sudo -u postgres pgbench -i -s 1000 -q postgres

echo "== t20: 20 млн строк, помещается в страничный кеш =="
$PSQL -q <<'SQL'
DROP TABLE IF EXISTS t20;
CREATE TABLE t20 AS SELECT * FROM pgbench_accounts LIMIT 20000000;
GRANT SELECT ON t20, pgbench_accounts TO test_low, test_high;
SQL

echo "== база oltp: pgbench -i -s 100 (1.5 GB, помещается в кеш) =="
sudo -u postgres dropdb --if-exists oltp
sudo -u postgres createdb -O app oltp
sudo -u postgres pgbench -i -s 100 -q oltp
sudo -u postgres psql -d oltp -qc "GRANT ALL ON ALL TABLES IN SCHEMA public TO app"

# ВАЖНО: расширение и его таблицы планов — объекты БАЗЫ ДАННЫХ, а не кластера.
# Если в базе oltp не завести расширение и планы, её сеансы плана не получат
# (pgpro_rp_session_plans покажет NULL), и приоритизация не сработает вообще —
# ни для этих сеансов, ни для тех, кто конкурирует с ними в других базах.
echo "== расширение и планы в базе oltp =="
sudo -u postgres psql -d oltp -q <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgpro_rp;
SELECT pgpro_rp_create_plan('plan_1_1_1', 1, 1, 1);
SELECT pgpro_rp_create_plan('plan_4_4_4', 4, 4, 4);
SELECT pgpro_rp_create_plan('plan_8_8_8', 8, 8, 8);
SELECT pgpro_rp_create_role_plan('app',     'plan_4_4_4');
SELECT pgpro_rp_create_role_plan('analyst', 'plan_4_4_4');
SELECT pgpro_rp_invalidate_cache();
SQL
sudo -u postgres psql -d oltp -P pager=off -c "select * from pgpro_rp_roles_plans_view order by rolname"

$PSQL -tAc "select 'pgbench_accounts '||pg_size_pretty(pg_total_relation_size('pgbench_accounts'))"
$PSQL -tAc "select 't20 '||pg_size_pretty(pg_total_relation_size('t20'))"

echo "== прогрев страничного кеша по t20 =="
$PSQL -qtAc "select count(*) from t20 where abalance = -999" >/dev/null
echo "== Готово =="
