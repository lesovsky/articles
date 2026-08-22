#!/bin/bash
# Сценарий 3: не убивать, а притормозить.
#
# Проверяем pgpro_rp_backend_set_plan(pid, plan) — понижение приоритета живому
# сеансу по его PID. Три части:
#
#   A. контроль: насколько вообще действует приоритизация в этой конфигурации
#      (сеанс с весом 1 против сеанса с весом 8, оба стартуют одновременно);
#   B. понижение УЖЕ ВЫПОЛНЯЮЩЕГОСЯ запроса — два сеанса с весом 8, одному на
#      8-й секунде применяется план 1/1/1, второй остаётся контрольным;
#   C. понижение сеанса, который выполняет два запроса подряд: понижаем во время
#      первого, смотрим на второй.
#
# Параллелизм всюду выключен: воркеры не подчиняются весам и смазывают эффект
# (см. 08-limits.sh).
#
# Результат: data/firefight.csv
set -e
source "$(dirname "$0")/lib.sh"

ensure_default_group

echo "part,run,session,phase,duration_ms" > "$DATA_DIR/firefight.csv"
set_interval 1s

RUNS=2

echo "== A. контроль: работает ли приоритизация в этой конфигурации =="
for run in $(seq 1 $RUNS); do
  burn_start test_high 4 400
  read -r d_low d_high < <(pair_query "$CPU_QUERY" 0)
  burn_stop
  csv firefight.csv A "$run" test_low  single "$d_low"
  csv firefight.csv A "$run" test_high single "$d_high"
  echo "  прогон$run: вес 1 ${d_low} ms, вес 8 ${d_high} ms"
done

# Пометка сеанса делается SQL-командой, а не переменной PGAPPNAME: psql запускается
# через sudo, а тот не пропускает окружение вызывающего.
tagged_query() {
  local s e
  s=$(date +%s%N)
  $PSQL -U test_high -h /tmp -d postgres -tA \
    -c "set application_name='$1'" \
    -c "set max_parallel_workers_per_gather=0" \
    -c "$CPU_QUERY" >/dev/null
  e=$(date +%s%N)
  echo $(( (e-s)/1000000 ))
}

echo
echo "== B. понижение уже выполняющегося запроса =="
for run in $(seq 1 $RUNS); do
  burn_start test_high 4 400
  ( tagged_query victim  > /tmp/ff_victim ) & v=$!
  ( tagged_query control > /tmp/ff_ref )    & r=$!
  sleep 8
  PID=$($PSQL -tAc "select pid from pg_stat_activity
                     where usename='test_high' and application_name='victim'
                     limit 1")
  $PSQL -qtAc "select pgpro_rp_backend_set_plan($PID,'plan_1_1_1')" >/dev/null
  sleep 6
  SL=$($PSQL -tAc "select coalesce(time_slept::text,'нет строки')
                     from pgpro_rp_stat_sleep_view where pid=$PID")
  wait $v $r
  burn_stop
  csv firefight.csv B "$run" victim  single "$(cat /tmp/ff_victim)"
  csv firefight.csv B "$run" control single "$(cat /tmp/ff_ref)"
  echo "  прогон$run: понижённый $(cat /tmp/ff_victim) ms, контрольный $(cat /tmp/ff_ref) ms"
  echo "            time_slept понижённого через 6 с: ${SL:-нет строки}"
done

echo
echo "== C. понижение действует на следующий запрос того же сеанса =="
# сеанс печатает отметку времени до первого запроса, между запросами и после второго
# $1 = application_name: по нему находим нужный сеанс. Выбирать «первый активный»
# нельзя — в паре одинаковых сеансов так легко понизить контрольный вместо целевого.
two_queries() {
  $PSQL -U test_high -h /tmp -d postgres -tA \
    -c "set application_name='$1'" \
    -c "set max_parallel_workers_per_gather=0" \
    -c "select 'M '||extract(epoch from clock_timestamp())" \
    -c "$CPU_QUERY" \
    -c "select 'M '||extract(epoch from clock_timestamp())" \
    -c "$CPU_QUERY" \
    -c "select 'M '||extract(epoch from clock_timestamp())" 2>/dev/null \
    | grep '^M ' | awk '{print $2}'
}

for run in $(seq 1 $RUNS); do
  burn_start test_high 4 400
  two_queries victim  > /tmp/ff_v_marks & v=$!
  two_queries control > /tmp/ff_c_marks & r=$!
  sleep 6
  PID=$($PSQL -tAc "select pid from pg_stat_activity
                     where usename='test_high' and application_name='victim'
                     limit 1")
  echo "  понижаем сеанс victim, pid $PID"
  $PSQL -qtAc "select pgpro_rp_backend_set_plan($PID,'plan_1_1_1')" >/dev/null
  wait $v $r
  burn_stop
  python3 - "$run" <<'PY'
import sys
run = sys.argv[1]
def dur(f):
    t = [float(x) for x in open(f).read().split()]
    return [round(t[i+1]-t[i], 1) for i in range(len(t)-1)]
v, c = dur('/tmp/ff_v_marks'), dur('/tmp/ff_c_marks')
print(f"  прогон{run}: понижённый {v[0]} / {v[1]} s, контрольный {c[0]} / {c[1]} s")
with open('/tmp/ff_c_rows', 'w') as fh:
    for sess, d in (('victim', v), ('control', c)):
        fh.write(f"C,{run},{sess},query1,{int(d[0]*1000)}\n")
        fh.write(f"C,{run},{sess},query2,{int(d[1]*1000)}\n")
PY
  cat /tmp/ff_c_rows >> "$DATA_DIR/firefight.csv"
done

echo "== Готово: $DATA_DIR/firefight.csv =="
