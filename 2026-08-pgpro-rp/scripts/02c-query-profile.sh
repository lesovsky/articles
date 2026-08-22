#!/bin/bash
# От чего зависит сила приоритизации: от длительности запроса или от его профиля.
#
# В 02-interval.sh запрос на ~12 с притормаживался в десять раз, а в
# 02b-interval-ratio.sh запрос на ~40 с — вообще никак. Единственное различие
# между ними — на что уходит время: у первого почти всё на чтение страниц,
# у второго на вычисление md5 поверх тех же прочитанных страниц.
#
# Здесь берём ДВА ЗАПРОСА ОДИНАКОВОЙ ДЛИТЕЛЬНОСТИ (около 40 с в одиночку) и
# гоняем в одинаковых условиях:
#   scan    — пятнадцать проходов по t20 без вычислений;
#   compute — один проход по t20 с тройным md5 на каждой строке.
#
# Результат: data/query-profile.csv
set -e
source "$(dirname "$0")/lib.sh"

ensure_default_group

echo "profile,role,weight,run,duration_ms" > "$DATA_DIR/query-profile.csv"

SCAN="select sum(c) from ($(for i in $(seq 1 15); do
        printf "select count(*) c from t20 union all "; done | sed 's/ union all $//')) x"
COMPUTE="select count(*) from t20 where md5(md5(md5(aid::text))) = 'нет-такого'"

set_interval 1s

echo "== калибровка на свободной машине =="
for name in scan compute; do
  [ "$name" = scan ] && Q="$SCAN" || Q="$COMPUTE"
  d=$(timed_query test_high "$Q" 0)
  csv query-profile.csv "$name" test_high 8 solo "$d"
  echo "  $name в одиночку: ${d} ms"
done

for name in scan compute; do
  [ "$name" = scan ] && Q="$SCAN" || Q="$COMPUTE"
  echo "== $name под конкуренцией, вес 1 против веса 8 =="
  for run in 1 2; do
    burn_start test_high 4 600
    read -r d_low d_high < <(pair_query "$Q" 0)
    burn_stop
    csv query-profile.csv "$name" test_low  1 "$run" "$d_low"
    csv query-profile.csv "$name" test_high 8 "$run" "$d_high"
    echo "  прогон$run: вес1 ${d_low} ms, вес8 ${d_high} ms"
  done
done

echo "== Готово: $DATA_DIR/query-profile.csv =="
