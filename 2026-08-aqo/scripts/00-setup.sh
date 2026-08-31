#!/bin/bash
# Подготовка стенда для исследования расширения aqo.
# Стенд: Postgres Pro Enterprise 18.6, Debian 12, 8 vCPU / 15 GB RAM / 197 GB SSD.
# Запускать на стенде от пользователя с sudo.
set -e

PSQL="sudo -u postgres psql"
SERVICE="postgrespro-ent-18"
DATADIR="/var/lib/pgpro/ent-18/data"
DATA_DIR="$(cd "$(dirname "$0")/../data" && pwd)"

echo "== 0. Фиксируем исходное состояние стенда =="
# Машина изначально сконфигурирована под PPEM: shared_buffers=96MB и набор
# библиотек мониторинга. Сохраняем как есть — это точка отката.
{
  echo "# состояние стенда до настройки, $(date -Iseconds)"
  $PSQL -tAc "select version()"
  $PSQL -tAc "select 'shared_preload_libraries = '||setting from pg_settings where name='shared_preload_libraries'"
} | tee "$DATA_DIR/stand-before.txt"

echo "== 1. shared_preload_libraries =="
# Было: 'pgpro_scheduler, pg_query_state, pg_wait_sampling, pgpro_stats'.
# pg_query_state и pgpro_stats вешают хуки на планировщик и executor — туда же,
# куда встраивается aqo. Их оверхед лёг бы прямо в измеряемое время планирования,
# поэтому оставляем только aqo и pg_stat_statements (нужен для учёта запросов).
#
# ALTER SYSTEM SET для этого параметра в прошлый раз (pgpro_rp) закавычил список
# целиком и сервер не стартовал, поэтому правим postgresql.auto.conf напрямую.
CUR=$($PSQL -tAc "show shared_preload_libraries")
WANT="aqo,pg_stat_statements"
if [[ "$CUR" != "$WANT" ]]; then
  sudo sed -i "/^shared_preload_libraries/d" "$DATADIR/postgresql.auto.conf"
  echo "shared_preload_libraries = '$WANT'" | sudo tee -a "$DATADIR/postgresql.auto.conf" >/dev/null
  NEED_RESTART=1
fi

echo "== 2. Параметры стенда =="
$PSQL -q <<'SQL'
-- Память. Датасет заведомо больше RAM: разница между хорошим и плохим планом
-- должна выражаться в секундах, а не в долях миллисекунды на попадании в кеш.
alter system set shared_buffers = '4GB';
alter system set effective_cache_size = '12GB';
alter system set maintenance_work_mem = '1GB';

-- work_mem фиксируем и документируем: он напрямую решает hash join против
-- nested loop. Если он «плавает», непонятно, чей это выбор — aqo или памяти.
alter system set work_mem = '64MB';

-- SSD.
alter system set random_page_cost = 1.1;

-- Параллелизм разрешён на уровне кластера, но в базовых замерах глушится
-- на уровне сессии. Параллельные планы — отдельный сценарий, не фон для всех.
alter system set max_parallel_workers_per_gather = 4;
alter system set max_parallel_workers = 8;
alter system set max_worker_processes = 8;

-- Чекпоинты не должны попадать в середину серии прогонов.
alter system set checkpoint_timeout = '30min';
alter system set max_wal_size = '8GB';
alter system set min_wal_size = '1GB';

-- JIT включается по порогу стоимости плана, а aqo меняет именно стоимость.
-- С включённым JIT часть эффекта оказалась бы не следствием лучшего плана,
-- а тем, что запрос перестал или начал компилироваться.
alter system set jit = off;

alter system set track_io_timing = on;

-- aqo выключен по умолчанию; включаем его отдельно, в сценариях.
alter system set aqo.enable = off;
SQL

sudo systemctl restart "$SERVICE"
sleep 3

echo "== 3. Расширения =="
$PSQL -qc "CREATE EXTENSION IF NOT EXISTS aqo"
$PSQL -qc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"

echo "== 4. Роль для запуска экспериментов =="
# Скрипты запускают psql от пользователя стенда, а не через sudo -u postgres:
# psql читает файлы прогонов и пишет планы правами клиента, и под postgres
# он не видит временных каталогов, созданных запускающим пользователем.
$PSQL -qc "do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='$USER') then
    execute format('create role %I login superuser', '$USER');
  end if;
end \$\$"

echo "== 5. База под эксперименты =="
# Отдельная база: aqo раскладывает знания по dbid, и aqo_reset(dbid) чистит
# ровно её, не задевая служебные базы кластера.
$PSQL -tAc "select 1 from pg_database where datname='aqotest'" | grep -q 1 \
  || $PSQL -qc "CREATE DATABASE aqotest"
$PSQL -d aqotest -qc "CREATE EXTENSION IF NOT EXISTS aqo"
$PSQL -d aqotest -qc "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"

echo "== 6. Итоговое состояние =="
{
  echo "# состояние стенда после настройки, $(date -Iseconds)"
  $PSQL -tAc "select version()"
  $PSQL -d aqotest -tAc "select 'aqo '||extversion from pg_extension where extname='aqo'"
  $PSQL -tAc "select name||' = '||setting||coalesce(' '||unit,'') from pg_settings
              where name in ('shared_preload_libraries','shared_buffers','work_mem',
                             'effective_cache_size','maintenance_work_mem','jit',
                             'random_page_cost','max_parallel_workers_per_gather',
                             'max_worker_processes','checkpoint_timeout','max_wal_size',
                             'track_io_timing')
              order by name"
  echo "-- параметры aqo (значения по умолчанию) --"
  $PSQL -d aqotest -tAc "select name||' = '||setting from pg_settings where name like 'aqo.%' order by name"
} | tee "$DATA_DIR/stand-after.txt"
