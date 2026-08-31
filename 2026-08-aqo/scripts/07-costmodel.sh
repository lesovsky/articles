#!/bin/bash
# Стоимостная модель против оценки кардинальности.
#
# На холодном кеше aqo добился ИДЕАЛЬНОЙ оценки строк на всех узлах q1 — и план
# не изменился: nested loop с 10007 случайными чтениями, восемь минут. Стоимость
# при этом почти не сдвинулась (269212 против 264947). Значит дело не в
# кардинальности, а в стоимостных константах: random_page_cost=1.1 объявляет
# случайное чтение почти бесплатным, тогда как диск стенда отдаёт ~43 MB/s.
#
# Проверяем три варианта на холодную: как есть, с реалистичным random_page_cost
# и с принудительным hash join.
set -e
source "$(dirname "$0")/lib.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
OUT="$DATA_DIR/costmodel.csv"
echo "variant,ms" > "$OUT"

cold_start() {
  sudo systemctl stop "$SERVICE"
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  sudo systemctl start "$SERVICE"
  for _ in $(seq 1 60); do $PG -tAc "select 1" >/dev/null 2>&1 && break; sleep 1; done
}

run_variant() {
  local name="$1" preset="$2"
  {
    echo "\\set ON_ERROR_STOP on"
    cat "$DATA_DIR/params.sql"
    echo "$preset"
    echo "\\o /dev/null"
    echo "\\timing on"
    cat "$QUERY_DIR/q1.sql"
  } > "$TMP/run.sql"
  cold_start
  local t
  t=$($PG -q -f "$TMP/run.sql" 2>"$TMP/err" | grep -oP 'Time: \K[0-9.,]+' | head -1 | tr ',' '.')
  [ -s "$TMP/err" ] && echo "  ОШИБКА $name: $(head -2 "$TMP/err")" >&2
  echo "$name,$t" >> "$OUT"
  echo "  [$(date +%H:%M:%S)] $name = $t ms"

  # план того же варианта, отдельным холодным прогоном
  {
    echo "\\set ON_ERROR_STOP on"
    cat "$DATA_DIR/params.sql"
    echo "$preset"
    echo "\\o $DATA_DIR/plans/cost-$name.txt"
    echo "explain (analyze, buffers)"
    cat "$QUERY_DIR/q1.sql"
  } > "$TMP/plan.sql"
  cold_start
  $PG -q -f "$TMP/plan.sql" >/dev/null 2>&1
}

# Как настроен стенд сейчас: диск объявлен быстрым SSD.
run_variant "rpc1.1-base" "set aqo.enable = off;"
# Реалистичная для этого диска стоимость случайного чтения.
run_variant "rpc4-base"   "set aqo.enable = off; set random_page_cost = 4;"
# Тот же rpc=4, но с aqo: меняет ли что-то точная оценка поверх честной стоимости.
run_variant "rpc4-aqo"    "set aqo.enable = on; set aqo.mode='frozen'; set aqo.advanced=on; set random_page_cost = 4;"
# Принудительный hash join: существует ли вообще план лучше.
run_variant "hashjoin"    "set aqo.enable = off; set enable_nestloop = off;"

echo "== Итог =="
column -s, -t "$OUT"
