#!/bin/bash
# Гипотеза 1: обучение и заморозка.
#
# Сценарий ровно тот, который документация называет рабочим для production:
# обучить в learn на типовой нагрузке, перевести в frozen, дальше только
# предсказания без обучения.
#
# Отдельно снимается кривая обучения по итерациям: сколько прогонов нужно,
# чтобы модель начала влиять на план, и меняется ли что-то после этого.
set -e
source "$(dirname "$0")/lib.sh"

ITERS=${ITERS:-10}
# aqo.advanced=off (дефолт) складывает ВСЕ запросы в общий класс fs=0 и знания
# разных запросов смешиваются; on даёт каждому классу своё пространство признаков.
ADVANCED=${ADVANCED:-off}
TAG_PREFIX=${TAG_PREFIX:-aqo}
LEARN="set aqo.enable = on; set aqo.mode = 'learn'; set aqo.advanced = $ADVANCED;"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# params.sql создаётся калибровкой в 02-baseline.sh. Без проверки обучение
# молча уходит в пустоту: неопределённая psql-переменная роняет запрос, а
# время «0.12 мс» выглядит как невероятный успех.
for v in product_hot product_cold city region category; do
  grep -q "set $v " "$DATA_DIR/params.sql" || { echo "в params.sql нет :$v — сначала прогоните 02-baseline.sh"; exit 1; }
done

echo "== 1. Сброс знаний aqo =="
# Обучение начинается с чистого листа, иначе непонятно, что именно измеряем.
$PG -tAc "select aqo_reset()" || $PG -tAc "select aqo_reset(NULL)"
$PG -tAc "select 'классов после сброса: '||count(*) from aqo_queries"

echo "== 2. Обучение: $ITERS итераций по всему набору =="
echo "iter,query,ms" > "$DATA_DIR/$TAG_PREFIX-learning-curve.csv"

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
      echo "$LEARN"
      if [ -n "$extra" ]; then echo "$extra"; fi
      echo "\\o /dev/null"
      echo "\\timing on"
      cat "$qfile"
    } > "$TMP/learn.sql"
    t=$($PG -q -f "$TMP/learn.sql" 2>"$TMP/err" | grep -oP 'Time: \K[0-9.,]+' | head -1 | tr ',' '.')
    if [ -s "$TMP/err" ]; then
      echo "ОШИБКА на итерации $i, запрос $q: $(head -2 "$TMP/err" | tr '\n' ' ')" >&2
      exit 1
    fi
    echo "$i,$q,$t" >> "$DATA_DIR/$TAG_PREFIX-learning-curve.csv"
    echo "  [$(date +%H:%M:%S)] итерация $i, $q = $t ms"
  done
done

echo "== 3. Что накопил aqo =="
{
  echo "# состояние aqo после обучения, $(date -Iseconds)"
  echo "-- классы запросов --"
  $PG -tAc "select 'классов: '||count(*) from aqo_queries"
  $PG -tAc "select fs||' | learn='||learn_aqo||' | use='||use_aqo||' | auto_tuning='||auto_tuning
            from aqo_queries order by fs"
  echo "-- использование памяти --"
  $PG -tAc "select * from aqo_memory_usage()" 2>/dev/null || echo "aqo_memory_usage() недоступна"
  $PG -tAc "select * from aqo_storage_usage()" 2>/dev/null || echo "aqo_storage_usage() недоступна"
  echo "-- ошибка оценки по классам: с aqo против без --"
  $PG -tAc "select * from aqo_cardinality_error(true)" 2>/dev/null || true
  echo "-- время выполнения по классам: с aqo против без --"
  $PG -tAc "select * from aqo_execution_time(true)" 2>/dev/null || true
} | tee "$DATA_DIR/$TAG_PREFIX-after-learn.txt"

echo "== 4. Замер в режиме frozen =="
# frozen: предсказания по накопленным знаниям, обучение выключено. Серия замеров
# не портит модель, поэтому результат воспроизводим.
TAG=$TAG_PREFIX-frozen \
PRESET="set aqo.enable = on; set aqo.mode = 'frozen'; set aqo.advanced = $ADVANCED;" \
  bash "$SCRIPT_DIR/02-baseline.sh"
