#!/bin/bash
# Итоговая серия на ЧЕСТНОЙ стоимостной модели.
#
# Все предыдущие замеры шли при random_page_cost=1.1 («диск SSD»), тогда как
# диск стенда отдаёт ~43 MB/s. На холодном q1 правка одной этой константы дала
# ускорение в 6.3 раза (505 -> 80 с), а aqo поверх неё — ноль. Значит вся
# предыдущая серия сравнивала режимы поверх заведомо кривой модели стоимости.
#
# Здесь: переобучение aqo на верной стоимости и три чередующихся раунда
# base против aqo. Переобучение обязательно — aqo учится на узлах фактического
# плана, а при rpc=4 планы другие, и старые знания относятся к несуществующим
# больше планам.
set -e
source "$(dirname "$0")/lib.sh"

COST="set random_page_cost = 4;"
ROUNDS=${ROUNDS:-3}
ITERS=${ITERS:-10}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "== 1. Сброс и переобучение на rpc=4 =="
$PG -tAc "select aqo_reset()"
for i in $(seq 1 "$ITERS"); do
  for q in q1 q2 q4 q5 q6 q7 q8 q3-hot q3-cold; do
    case "$q" in
      q3-hot)  qfile="$QUERY_DIR/q3.sql"; extra="\\set product_id :product_hot" ;;
      q3-cold) qfile="$QUERY_DIR/q3.sql"; extra="\\set product_id :product_cold" ;;
      *)       qfile="$QUERY_DIR/$q.sql"; extra="" ;;
    esac
    {
      echo "\\set ON_ERROR_STOP on"
      cat "$DATA_DIR/params.sql"
      echo "$COST set aqo.enable = on; set aqo.mode = 'learn'; set aqo.advanced = on;"
      if [ -n "$extra" ]; then echo "$extra"; fi
      echo "\\o /dev/null"
      cat "$qfile"
    } > "$TMP/learn.sql"
    $PG -q -f "$TMP/learn.sql" > /dev/null 2>"$TMP/err"
    if [ -s "$TMP/err" ]; then echo "ОШИБКА $i/$q: $(head -1 "$TMP/err")" >&2; exit 1; fi
  done
  echo "  [$(date +%H:%M:%S)] итерация $i завершена"
done
$PG -tAc "select 'классов обучено: '||count(*) from aqo_queries where use_aqo"

echo "== 2. Чередующиеся раунды base / aqo на rpc=4 =="
for r in $(seq 1 "$ROUNDS"); do
  TAG="fin-base-$r" PRESET="$COST set aqo.enable = off;" \
    bash "$SCRIPT_DIR/02-baseline.sh" >/dev/null 2>&1
  echo "  [$(date +%H:%M:%S)] раунд $r: базовая линия готова"
  TAG="fin-aqo-$r" PRESET="$COST set aqo.enable = on; set aqo.mode='frozen'; set aqo.advanced=on;" \
    bash "$SCRIPT_DIR/02-baseline.sh" >/dev/null 2>&1
  echo "  [$(date +%H:%M:%S)] раунд $r: aqo готов"
done

echo "== 3. Итог: время, ошибка оценки и СМЕНА ФОРМЫ ПЛАНА =="
# Форма плана — ключевая колонка: рабочая гипотеза в том, что выигрыш во времени
# появляется только там, где точная оценка переворачивает выбор плана.
python3 - "$DATA_DIR" "$ROUNDS" <<'PY'
import csv, os, sys, statistics
d, rounds = sys.argv[1], int(sys.argv[2])

def load(tag):
    p = os.path.join(d, tag + ".csv")
    return {r["query"]: r for r in csv.DictReader(open(p))} if os.path.exists(p) else {}

base = [load(f"fin-base-{i}") for i in range(1, rounds+1)]
aqo  = [load(f"fin-aqo-{i}")  for i in range(1, rounds+1)]
qs = sorted({q for x in base+aqo for q in x})

print(f"{'query':9} {'base мс':>9} {'aqo мс':>9} {'дельта':>8} {'разброс':>8} "
      f"{'ошибка base':>12} {'ошибка aqo':>11}  план")
for q in qs:
    b = [float(x[q]["median_ms"]) for x in base if q in x and x[q]["median_ms"]]
    a = [float(x[q]["median_ms"]) for x in aqo  if q in x and x[q]["median_ms"]]
    if not b or not a: continue
    bm, am = statistics.median(b), statistics.median(a)
    spread = max((max(b)-min(b))/bm, (max(a)-min(a))/am) * 100
    be = next((x[q]["max_err"] for x in base if q in x), "?")
    ae = next((x[q]["max_err"] for x in aqo  if q in x), "?")
    sb = next((x[q]["shape"] for x in base if q in x), "")
    sa = next((x[q]["shape"] for x in aqo  if q in x), "")
    changed = "СМЕНИЛСЯ" if sb != sa else "тот же"
    print(f"{q:9} {bm:9.1f} {am:9.1f} {(am-bm)/bm*100:+7.1f}% {spread:7.1f}% "
          f"{be:>12} {ae:>11}  {changed}")
PY
