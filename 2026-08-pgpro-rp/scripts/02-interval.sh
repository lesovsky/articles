#!/bin/bash
# Эксперимент 1: что делает usage_tracking_interval.
#
# Проверяем две вещи сразу:
#   а) при значении 0 (это значение по умолчанию!) приоритизация не работает вообще;
#   б) значение интервала задаёт порог длительности запроса, начиная с которого
#      приоритизация вообще включается — короткие запросы проскакивают.
#
# Результат: data/interval.csv
set -e
source "$(dirname "$0")/lib.sh"

ensure_default_group

echo "interval,role,weight,query_kind,run,duration_ms" > "$DATA_DIR/interval.csv"

# короткий запрос — около 1.5 с, длинный — около 7 с на свободном стенде
SHORT_QUERY="select count(*) from t20 where abalance = -999"

for interval in 0 1s 5s 60s; do
  set_interval "$interval"
  echo "== usage_tracking_interval = $interval =="

  for kind in short long; do
    [ "$kind" = short ] && Q="$SHORT_QUERY" || Q="$CPU_QUERY"

    for run in 1 2 3; do
      # 4 фоновых сеанса с весом 8 создают конкуренцию за 4 vCPU;
      # таймаут 300 с заведомо перекрывает самый долгий замер
      burn_start test_high 4 300

      read -r d_low d_high < <(pair_query "$Q" 0)

      burn_stop

      csv interval.csv "$interval" test_low  1 "$kind" "$run" "$d_low"
      csv interval.csv "$interval" test_high 8 "$kind" "$run" "$d_high"
      echo "  $kind run$run: вес1 ${d_low}ms  вес8 ${d_high}ms"
    done
  done

  # признак работы механизма в журнале и в представлении
  $PSQL -tAc "select count(*) from pgpro_rp_stat_sleep_view" \
    | sed "s/^/  строк в pgpro_rp_stat_sleep_view: /"
done

set_interval 1s
echo "== Готово: $DATA_DIR/interval.csv =="
