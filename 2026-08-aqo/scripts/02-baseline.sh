#!/bin/bash
# Базовая линия: как планировщик Postgres Pro справляется с набором запросов
# БЕЗ aqo. Всё, что будет измеряться дальше, сравнивается именно с этими числами.
#
# Замеряется по каждому запросу:
#   - медиана времени выполнения из серии прогонов (без инструментации EXPLAIN);
#   - расхождение оценки и факта в корне плана и в худшем узле;
#   - форма плана — по ней видно смену стратегии соединения.
#
# Константы запросов не зашиты, а подбираются по фактическим данным (шаг 1):
# для перекоса нужны значения ЗА пределами MCV, а какие именно попали в MCV —
# знает только собранная статистика.
set -e
source "$(dirname "$0")/lib.sh"

RUNS=${RUNS:-3}                 # замеров времени на запрос (плюс один прогрев)
TIMEOUT_MS=${TIMEOUT_MS:-900000} # защита от прогона, который не заканчивается
TAG=${TAG:-baseline}            # метка серии, попадает в имена файлов
PRESET=${PRESET:-}              # SQL сессии для всей серии, например включение aqo
PLAN_DIR="$DATA_DIR/plans"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$PLAN_DIR"

echo "== 1. Калибровка констант по фактическим данным =="

# Пара city/region/country средней частоты — не самая редкая и не самая частая.
read -r CITY REGION COUNTRY <<<"$($PG -tAF' ' -c "
  select city, region, country from customers
  group by 1,2,3 order by count(*) desc offset 100 limit 1")"

# product_id вне MCV: HOT — самый частый из оставшихся (планировщик его
# недооценит), COLD — из длинного хвоста (переоценит).
read -r PROD_HOT PROD_COLD <<<"$($PG -tAF' ' -c "
  with mcv as (
    select unnest(most_common_vals::text::int[]) v
    from pg_stats where tablename='fact_sales' and attname='product_id'
  ),
  freq as (
    select product_id, count(*) n from fact_sales
    where product_id not in (select v from mcv)
    group by 1
  )
  select
    (select product_id from freq order by n desc limit 1),
    (select product_id from freq order by n asc, product_id desc limit 1)")"

CATEGORY=$($PG -tAc "select category from products group by 1 order by count(*) desc offset 5 limit 1")
CUSTOMER=$($PG -tAc "select customer_id from customers where segment='vip' limit 1")

cat > "$TMP/params.sql" <<EOF
\set city '$CITY'
\set region '$REGION'
\set country '$COUNTRY'
\set segment 'vip'
\set category '$CATEGORY'
\set customer_id $CUSTOMER
\set month '2025-06-01 00:00:00+03'
\set since '2025-01-01 00:00:00+03'
\set until '2024-12-31 23:59:59+03'
\set product_hot $PROD_HOT
\set product_cold $PROD_COLD
EOF
cp "$TMP/params.sql" "$DATA_DIR/params.sql"

{
  echo "# константы серии $TAG, $(date -Iseconds)"
  echo "city=$CITY region=$REGION country=$COUNTRY category=$CATEGORY customer_id=$CUSTOMER"
  echo "product_hot=$PROD_HOT product_cold=$PROD_COLD"
  echo "-- MCV по product_id: сколько значений покрыто --"
  $PG -tAc "select 'mcv_size='||coalesce(array_length(most_common_vals::text::int[],1),0)
            from pg_stats where tablename='fact_sales' and attname='product_id'"
  echo "-- фактические частоты выбранных product_id --"
  $PG -tAc "select 'hot  $PROD_HOT -> '||count(*) from fact_sales where product_id=$PROD_HOT"
  $PG -tAc "select 'cold $PROD_COLD -> '||count(*) from fact_sales where product_id=$PROD_COLD"
} | tee "$DATA_DIR/$TAG-params.txt"

echo "== 2. Прогоны =="
echo "query,median_ms,root_est,root_act,root_err,max_err,max_err_node,exec_ms,plan_ms,shape" \
  > "$DATA_DIR/$TAG.csv"

run_query() {
  local label="$1" qfile="$2" extra="$3"

  # Файл прогона: параметры, затем сам запрос. Результат в /dev/null —
  # меряем работу сервера, а не печать строк в терминал.
  {
    echo "\\set ON_ERROR_STOP on"
    cat "$TMP/params.sql"
    if [ -n "$PRESET" ]; then echo "$PRESET"; fi
    if [ -n "$extra" ]; then echo "$extra"; fi
    echo "set statement_timeout = $TIMEOUT_MS;"
    echo "\\o /dev/null"
    echo "\\timing on"
    cat "$qfile"
  } > "$TMP/run.sql"

  # Прогрев: первый прогон греет кеш и не попадает в статистику.
  echo "  [$(date +%H:%M:%S)] $label: прогрев" >&2
  $PG -q -f "$TMP/run.sql" > /dev/null 2>&1 || true

  local times=()
  for i in $(seq 1 "$RUNS"); do
    local t
    # psql печатает время в локали сервера: «Time: 101204,913 ms». Запятую
    # приводим к точке, иначе дальше всё считается по целой части.
    t=$($PG -q -f "$TMP/run.sql" 2>"$TMP/err" | grep -oP 'Time: \K[0-9.,]+' | head -1 | tr ',' '.')
    if [ -s "$TMP/err" ]; then
      echo "  [$(date +%H:%M:%S)] $label: ОШИБКА psql: $(head -2 "$TMP/err" | tr '\n' ' ')" >&2
      t=""
    fi
    if [ -z "$t" ]; then
      echo "  [$(date +%H:%M:%S)] $label: прогон $i не дал времени — пропуск" >&2
      continue
    fi
    echo "  [$(date +%H:%M:%S)] $label: прогон $i = $t ms" >&2
    times+=("$t")
  done
  if [ ${#times[@]} -eq 0 ]; then
    echo "$label,ERROR,,,,,,,," >> "$DATA_DIR/$TAG.csv"
    return 0
  fi
  local median
  median=$(printf '%s\n' "${times[@]}" | sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}')

  # План снимаем отдельным прогоном: инструментация EXPLAIN ANALYZE сама по себе
  # стоит времени и в измерение длительности попадать не должна.
  {
    echo "\\set ON_ERROR_STOP on"
    cat "$TMP/params.sql"
    if [ -n "$PRESET" ]; then echo "$PRESET"; fi
    if [ -n "$extra" ]; then echo "$extra"; fi
    echo "\\t on"
    echo "\\a"
    echo "\\o $PLAN_DIR/$TAG-$label.json"
    echo "explain (analyze, buffers, format json)"
    cat "$qfile"
  } > "$TMP/plan.sql"
  $PG -q -f "$TMP/plan.sql" > /dev/null 2>&1

  # Текстовый план — для чтения человеком.
  {
    echo "\\set ON_ERROR_STOP on"
    cat "$TMP/params.sql"
    if [ -n "$PRESET" ]; then echo "$PRESET"; fi
    if [ -n "$extra" ]; then echo "$extra"; fi
    echo "\\o $PLAN_DIR/$TAG-$label.txt"
    echo "explain (analyze, buffers, settings)"
    cat "$qfile"
  } > "$TMP/plantxt.sql"
  $PG -q -f "$TMP/plantxt.sql" > /dev/null 2>&1

  local stat
  stat=$(python3 "$SCRIPT_DIR/planstat.py" "$PLAN_DIR/$TAG-$label.json" 2>/dev/null || echo ",,,,,,,")
  echo "$label,$median,$stat" | tee -a "$DATA_DIR/$TAG.csv"
}

for q in q1 q2 q4 q5 q6 q7 q8; do
  run_query "$q" "$QUERY_DIR/$q.sql" ""
done
# q3 прогоняется дважды: недооценка частого значения и переоценка редкого.
run_query "q3-hot"  "$QUERY_DIR/q3.sql" "\\set product_id :product_hot"
run_query "q3-cold" "$QUERY_DIR/q3.sql" "\\set product_id :product_cold"

echo "== 3. Готово =="
column -s, -t "$DATA_DIR/$TAG.csv" | cut -c1-200
