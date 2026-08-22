#!/bin/bash
# Установка pgpro_rp и подготовка стенда.
# Стенд: Postgres Pro Enterprise 18.4, Debian 12, 4 vCPU / 8 GB RAM / 100 GB SSD.
# Запускать от пользователя с sudo.
set -e

PSQL="sudo -u postgres psql"
DATADIR=$($PSQL -tAc "show data_directory")
SERVICE="postgrespro-ent-18"

echo "== 1. Добавляем pgpro_rp в shared_preload_libraries =="
# ВНИМАНИЕ: ALTER SYSTEM SET shared_preload_libraries = 'a, b' закавычивает список
# целиком и сервер не стартует ("could not access file \"a, b\"").
# Поэтому правим postgresql.auto.conf напрямую, без пробелов после запятых.
CUR=$($PSQL -tAc "show shared_preload_libraries")
if [[ "$CUR" != *pgpro_rp* ]]; then
  NEW=$(echo "$CUR,pgpro_rp" | tr -d ' ')
  sudo sed -i "/^shared_preload_libraries/d" "$DATADIR/postgresql.auto.conf"
  echo "shared_preload_libraries = '$NEW'" | sudo tee -a "$DATADIR/postgresql.auto.conf" >/dev/null
  sudo systemctl restart "$SERVICE"
  sleep 3
fi
$PSQL -tAc "show shared_preload_libraries"

echo "== 2. Создаём расширение =="
$PSQL -qc "CREATE EXTENSION IF NOT EXISTS pgpro_rp"
$PSQL -tAc "select extname||' '||extversion from pg_extension where extname='pgpro_rp'"

echo "== 3. Параметры стенда =="
# usage_tracking_interval по умолчанию равен 0 — при нуле приоритизация НЕ РАБОТАЕТ.
# Специально не выставляем здесь: это отдельный эксперимент в 02-interval.sh.
if [ "$($PSQL -tAc "show shared_buffers")" != "1GB" ]; then
  $PSQL -qtAc "alter system set shared_buffers='1GB'"
  sudo systemctl restart "$SERVICE"; sleep 3
fi
$PSQL -tAc "show shared_buffers"
$PSQL -tAc "show usage_tracking_interval"

echo "== 4. Роли и планы приоритизации =="
$PSQL -q <<'SQL'
-- test_low / test_high — синтетические роли для микро-замеров механизма
-- app / analyst — роли из сценария «шумный сосед»
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['test_low','test_high','app','analyst'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REASSIGN OWNED BY %I TO postgres', r);
      EXECUTE format('DROP OWNED BY %I', r);
      EXECUTE format('DROP ROLE %I', r);
    END IF;
  END LOOP;
END $$;

CREATE ROLE test_low  LOGIN;
CREATE ROLE test_high LOGIN;
CREATE ROLE app       LOGIN;
CREATE ROLE analyst   LOGIN;

-- планы создаём идемпотентно: повторный create_plan падает с ошибкой
DO $$
DECLARE
  p record;
BEGIN
  PERFORM pgpro_rp_cleanup_roles_plans();
  FOR p IN SELECT * FROM (VALUES
      ('plan_1_1_1',  1,1,1),
      ('plan_2_2_2',  2,2,2),
      ('plan_4_4_4',  4,4,4),
      ('plan_8_8_8',  8,8,8),
      ('plan_io_low', 4,1,4),
      ('plan_io_high',4,8,4)
    ) AS t(name, cpu, ior, iow)
  LOOP
    BEGIN
      PERFORM pgpro_rp_create_plan(p.name, p.cpu, p.ior, p.iow);
    EXCEPTION WHEN OTHERS THEN
      PERFORM pgpro_rp_update_plan(p.name, jsonb_build_object(
        'session_cpu_weight', p.cpu,
        'session_ioread_weight', p.ior,
        'session_iowrite_weight', p.iow));
    END;
  END LOOP;
END $$;

SELECT pgpro_rp_create_role_plan('test_low',  'plan_1_1_1');
SELECT pgpro_rp_create_role_plan('test_high', 'plan_8_8_8');
SELECT pgpro_rp_create_role_plan('app',       'plan_4_4_4');
SELECT pgpro_rp_create_role_plan('analyst',   'plan_4_4_4');
SELECT pgpro_rp_invalidate_cache();

-- права на данные: app пишет, analyst и синтетические роли только читают
GRANT ALL    ON pgbench_accounts, pgbench_branches, pgbench_tellers, pgbench_history TO app;
GRANT SELECT ON pgbench_accounts TO analyst, test_low, test_high;
GRANT SELECT ON t20 TO analyst, test_low, test_high, app;
SQL
$PSQL -P pager=off -c "select * from pgpro_rp_roles_plans_view order by group_name, rolname"
echo "== Готово =="
