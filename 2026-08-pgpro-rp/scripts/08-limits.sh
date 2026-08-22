#!/bin/bash
# Секция «чего инструмент не обещает».
#
# Четыре проверки:
#   1. параллельные воркеры не тормозятся — приоритизация обходится сама собой;
#   2. непривилегированная роль снимает с себя ограничение обычным SET,
#      и правами это не закрывается;
#   3. RESET конкретного параметра теряет план, RESET ALL и DISCARD ALL — нет;
#   4. веса принимают только значения 1, 2, 4 и 8.
#
# Результат (пишется через tee вызывающей стороной): data/limits.txt
set -e
source "$(dirname "$0")/lib.sh"

ensure_default_group
# вывод пишет вызывающая сторона: bash script | tee data/файл

set_interval 1s
U="sudo -u postgres psql -U test_low -h /tmp -d postgres -tA"

echo "== 1. Параллельные воркеры =="
burn_start test_high 4 120
( timed_query test_low "$CPU_QUERY" 2 > /tmp/lim_par ) &
Q_PID=$!
sleep 6
$PSQL -P pager=off -c "
select a.pid, a.backend_type, a.usename, a.leader_pid,
       coalesce(sp.plan,'(нет)') as plan,
       coalesce(sl.time_slept::text,'(не тормозится)') as time_slept
  from pg_stat_activity a
  left join pgpro_rp_session_plans sp on sp.pid = a.pid
  left join pgpro_rp_stat_sleep_view sl on sl.pid = a.pid
 where a.usename='test_low'
    or a.leader_pid in (select pid from pg_stat_activity where usename='test_low')
 order by a.leader_pid nulls first, a.pid"
wait $Q_PID
echo "  время параллельного запроса под конкуренцией: $(cat /tmp/lim_par) ms"
burn_stop

echo
echo "== сравнение: тот же запрос без параллелизма и с ним, вес 1 против веса 8 =="
for w in 0 2; do
  burn_start test_high 4 300
  read -r dl dh < <(pair_query "$CPU_QUERY" $w)
  burn_stop
  echo "  workers=$w : вес1 ${dl} ms, вес8 ${dh} ms"
done

echo
echo "== 1b. Величина эффекта зависит от состава нагрузки =="
echo "-- один сеанс весом 1 против четырёх сеансов весом 8 (см. выше, workers=0)"
echo "-- теперь поровну: 4 сеанса весом 1 против 4 сеансов весом 8, без фоновой нагрузки"
for i in 1 2 3 4; do
  ( timed_query test_low  "$CPU_QUERY" 0 > /tmp/eq_low_$i  ) &
  ( timed_query test_high "$CPU_QUERY" 0 > /tmp/eq_high_$i ) &
done
wait
echo "  вес 1: $(cat /tmp/eq_low_1) $(cat /tmp/eq_low_2) $(cat /tmp/eq_low_3) $(cat /tmp/eq_low_4) ms"
echo "  вес 8: $(cat /tmp/eq_high_1) $(cat /tmp/eq_high_2) $(cat /tmp/eq_high_3) $(cat /tmp/eq_high_4) ms"

echo
echo "== 2. Обход через SET =="
echo "  назначенный вес: $($U -c 'show session_cpu_weight')"
echo "  после SET: $($U -c 'set session_cpu_weight=8' -c 'show session_cpu_weight' | tail -1)"
echo "  context параметра: $($PSQL -tAc "select context from pg_settings where name='session_cpu_weight'")"
echo "  пробуем закрыть правами:"
$PSQL -tAc "revoke set on parameter session_cpu_weight from public" | sed 's/^/    /'
echo "    записей в pg_parameter_acl: $($PSQL -tAc 'select count(*) from pg_parameter_acl')"
echo "    после revoke SET всё равно даёт: $($U -c 'set session_cpu_weight=8' -c 'show session_cpu_weight' | tail -1)"

echo
echo "== 3. RESET, RESET ALL, DISCARD ALL =="
echo "  RESET session_cpu_weight -> $($U -c 'set session_cpu_weight=8' -c 'reset session_cpu_weight' -c 'show session_cpu_weight' | tail -1)"
echo "  RESET ALL                -> $($U -c 'show session_cpu_weight' -c 'reset all' -c 'show session_cpu_weight' | tail -1)"
echo "  DISCARD ALL              -> $($U -c 'show session_cpu_weight' -c 'discard all' -c 'show session_cpu_weight' | tail -1)"

echo
echo "== 4. Допустимые значения весов =="
$U -c 'set session_cpu_weight=3' 2>&1 | sed 's/^/  SET ...=3: /' | head -1
$PSQL -tAc "select pgpro_rp_create_plan('plan_3_3_3',3,3,3)" 2>&1 | sed 's/^/  create_plan(3,3,3): /' | head -1

echo
echo "== 5. Что попадает в журнал сервера =="
sudo grep -h -iE 'priority worker' /var/log/postgresql/*.log 2>/dev/null | tail -3 | sed 's/^/  /'
echo "  (записей о самом факте троттлинга в журнале нет даже при log_min_messages=debug1)"
echo "== Готово =="
