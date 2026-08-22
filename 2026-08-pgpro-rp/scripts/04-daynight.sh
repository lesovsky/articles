#!/bin/bash
# Сценарий 2: день и ночь.
#
# Группы назначений планов и переключение между ними. Проверяем главное:
# действует ли переключение на уже открытые сеансы (короткий ответ — нет).
#
# Результат: вывод на экран, data/daynight.txt
set -e
source "$(dirname "$0")/lib.sh"
# вывод пишет вызывающая сторона: bash script | tee data/файл

set_interval 1s

echo "== Создаём группы =="
$PSQL -q <<'SQL' 2>&1 | grep -v '^$' || true
SELECT pgpro_rp_create_group('day');
SELECT pgpro_rp_create_group('night');

-- днём приложение в приоритете, ETL придушен
SELECT pgpro_rp_create_group_role_plan('day', 'app',     'plan_8_8_8');
SELECT pgpro_rp_create_group_role_plan('day', 'analyst', 'plan_1_1_1');

-- ночью наоборот
SELECT pgpro_rp_create_group_role_plan('night', 'app',     'plan_1_1_1');
SELECT pgpro_rp_create_group_role_plan('night', 'analyst', 'plan_8_8_8');
SQL

$PSQL -P pager=off -c "select * from pgpro_rp_roles_plans_view order by group_name, rolname"

echo
echo "== ВНИМАНИЕ: pgpro_rp_set_active_group — это ПРОЦЕДУРА, не функция =="
echo "-- через SELECT (документация F.56.4.3 описывает её как returns void):"
$PSQL -tAc "select pgpro_rp_set_active_group('day')" 2>&1 | head -2
echo "-- через CALL (как в примере F.56.2.2):"
$PSQL -tAc "call pgpro_rp_set_active_group('day')" 2>&1 | head -2
$PSQL -qtAc "select pgpro_rp_invalidate_cache()" >/dev/null

echo
echo "== Дневной режим: какой вес получает analyst =="
$PSQL -U analyst -h /tmp -d postgres -tAc 'show session_cpu_weight'

echo
echo "== Переключаем на night при живом сеансе analyst =="
(
  $PSQL -U analyst -h /tmp -d postgres -tA \
    -c 'show session_cpu_weight' \
    -c 'select pg_sleep(8)' \
    -c 'show session_cpu_weight' 2>&1 | grep -vE '^$' | sed 's/^/   открытый сеанс: /'
) &
sleep 2
$PSQL -qtAc "call pgpro_rp_set_active_group('night')" >/dev/null
$PSQL -qtAc "select pgpro_rp_invalidate_cache()" >/dev/null
echo "   (в момент t+2s активной стала группа night)"
wait

echo
echo "== Новый сеанс analyst после переключения =="
$PSQL -U analyst -h /tmp -d postgres -tAc 'show session_cpu_weight'
echo "== Активная группа сейчас: $($PSQL -tAc 'select pgpro_rp_get_active_group()') =="

# ВАЖНО: возвращаем группу по умолчанию. Оставленная активной группа day означает,
# что у ролей test_low/test_high планов нет и все последующие эксперименты
# меряют отсутствие приоритизации.
$PSQL -qtAc "call pgpro_rp_set_active_group('default')" >/dev/null
$PSQL -qtAc "select pgpro_rp_invalidate_cache()" >/dev/null
echo "== Готово, активная группа возвращена в default =="
