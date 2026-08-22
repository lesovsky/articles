#!/bin/bash
# Проверка правила: важен не сам интервал, а отношение длительности запроса к нему.
#
# В 02-interval.sh эффект был виден только при интервале 1 с на запросе ≈10 с
# (отношение 10:1). При интервале 5 с тот же запрос — отношение 2:1 — не
# притормаживался вовсе. Здесь берём запрос ≈60 с и гоняем его при интервалах
# 1, 5 и 60 с, то есть при отношениях 60:1, 12:1 и 1:1.
#
# Если правило про отношение верно, эффект должен быть при 1 и 5 с и пропасть при 60 с.
#
# Результат: data/interval-ratio.csv
set -e
source "$(dirname "$0")/lib.sh"

ensure_default_group

echo "interval,role,weight,run,duration_ms" > "$DATA_DIR/interval-ratio.csv"

# ≈40 с в одиночку: тройной md5 по всем 20 млн строк.
# Вариант через generate_series не годится — планировщик проталкивает фильтр
# под соединение, и запрос остаётся коротким.
LONG60="select count(*) from t20 where md5(md5(md5(aid::text))) = 'нет-такого'"

echo "== калибровка длительности на свободной машине =="
set_interval 0
d=$(timed_query test_high "$LONG60" 0)
echo "  запрос в одиночку: ${d} ms"
csv interval-ratio.csv solo test_high 8 0 "$d"

for interval in 1s 5s 60s; do
  set_interval "$interval"
  echo "== usage_tracking_interval = $interval =="
  for run in 1 2; do
    burn_start test_high 4 600
    read -r d_low d_high < <(pair_query "$LONG60" 0)
    burn_stop
    csv interval-ratio.csv "$interval" test_low  1 "$run" "$d_low"
    csv interval-ratio.csv "$interval" test_high 8 "$run" "$d_high"
    echo "  прогон$run: вес1 ${d_low} ms, вес8 ${d_high} ms"
  done
done

set_interval 1s
echo "== Готово: $DATA_DIR/interval-ratio.csv =="
