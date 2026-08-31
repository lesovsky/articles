#!/bin/bash
# Холодный кеш: сколько стоит ошибка оценки, когда за неё платит диск.
#
# Зачем отдельный сценарий. Основной датасет помещается в память, и там nested
# loop дёшев: на q1 он в 3.7 раза БЫСТРЕЕ hash join, хотя оценка занижена в 76
# раз. На датасете, не влезающем в кеш, тот же выбор переворачивался — hash join
# оказывался в 30 раз быстрее. То есть в кеше ошибка оценки почти ничего не
# стоит, и главный вопрос исследования — конвертируется ли точная оценка в
# скорость — там просто не проверяется.
#
# Каждый прогон стартует с полностью холодного кеша: сбрасывается page cache ОС
# и перезапускается сервер, иначе shared_buffers сохранит прогретое состояние.
set -e
source "$(dirname "$0")/lib.sh"

RUNS=${RUNS:-2}
QUERIES=${QUERIES:-"q1 q2 q5"}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
OUT="$DATA_DIR/cold.csv"
echo "query,mode,run,ms" > "$OUT"

cold_start() {
  sudo systemctl stop "$SERVICE"
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  sudo systemctl start "$SERVICE"
  # ждём готовности сервера, а не спим наугад
  for _ in $(seq 1 60); do
    $PG -tAc "select 1" >/dev/null 2>&1 && break
    sleep 1
  done
}

for q in $QUERIES; do
  for mode in base aqo; do
    case "$mode" in
      base) preset="set aqo.enable = off;" ;;
      aqo)  preset="set aqo.enable = on; set aqo.mode = 'frozen'; set aqo.advanced = on;" ;;
    esac
    for r in $(seq 1 "$RUNS"); do
      {
        echo "\\set ON_ERROR_STOP on"
        cat "$DATA_DIR/params.sql"
        echo "$preset"
        echo "\\o /dev/null"
        echo "\\timing on"
        cat "$QUERY_DIR/$q.sql"
      } > "$TMP/run.sql"

      cold_start
      t=$($PG -q -f "$TMP/run.sql" 2>"$TMP/err" | grep -oP 'Time: \K[0-9.,]+' | head -1 | tr ',' '.')
      if [ -s "$TMP/err" ]; then
        echo "  ОШИБКА $q/$mode: $(head -2 "$TMP/err" | tr '\n' ' ')" >&2
        t=""
      fi
      echo "$q,$mode,$r,$t" >> "$OUT"
      echo "  [$(date +%H:%M:%S)] $q / $mode / прогон $r = $t ms"
    done
  done
done

echo "== Планы на холодную, для протокола =="
for q in $QUERIES; do
  for mode in base aqo; do
    case "$mode" in
      base) preset="set aqo.enable = off;" ;;
      aqo)  preset="set aqo.enable = on; set aqo.mode = 'frozen'; set aqo.advanced = on;" ;;
    esac
    {
      echo "\\set ON_ERROR_STOP on"
      cat "$DATA_DIR/params.sql"
      echo "$preset"
      echo "\\o $DATA_DIR/plans/cold-$q-$mode.txt"
      echo "explain (analyze, buffers)"
      cat "$QUERY_DIR/$q.sql"
    } > "$TMP/plan.sql"
    cold_start
    $PG -q -f "$TMP/plan.sql" >/dev/null 2>&1
  done
done

echo "== Итог =="
python3 - "$OUT" <<'PY'
import csv, sys, statistics
rows = list(csv.DictReader(open(sys.argv[1])))
data = {}
for r in rows:
    if r["ms"]:
        data.setdefault((r["query"], r["mode"]), []).append(float(r["ms"]))
queries = sorted({q for q, _ in data})
print(f"{'query':6} {'base мс':>12} {'aqo мс':>12} {'дельта':>9}")
for q in queries:
    b = data.get((q, "base")); a = data.get((q, "aqo"))
    if not b or not a:
        continue
    bm, am = statistics.median(b), statistics.median(a)
    print(f"{q:6} {bm:12.0f} {am:12.0f} {(am-bm)/bm*100:+8.1f}%")
PY
