#!/bin/bash
# Контрольная линия: расширенная статистика вместо aqo.
#
# Прежде чем измерять пользу aqo, надо ответить на первый вопрос грамотного DBA:
# а может, хватило бы штатной многоколоночной статистики? Ожидание такое:
# CREATE STATISTICS закрывает механизмы 1 и 6 (корреляция внутри таблицы,
# число групп) и НЕ помогает механизмам 2, 3, 4 — там корреляция лежит между
# таблицами либо статистики нет вовсе.
set -e
source "$(dirname "$0")/lib.sh"

echo "== 1. Расширенная статистика =="
$PG -q <<'SQL'
drop statistics if exists st_customers_geo;
drop statistics if exists st_products_cat;

-- ndistinct лечит оценку числа групп в GROUP BY, dependencies — перемножение
-- селективностей коррелированных предикатов, mcv — конкретные частые сочетания.
create statistics st_customers_geo (ndistinct, dependencies, mcv)
  on city, region, country from customers;

create statistics st_products_cat (ndistinct, dependencies, mcv)
  on category, subcategory from products;

analyze customers;
analyze products;
SQL

{
  echo "# расширенная статистика, $(date -Iseconds)"
  $PG -tAc "select stxname||' | '||stxkeys||' | размер mcv: '||
            coalesce(length(stxdmcv::text)::text,'нет')
            from pg_statistic_ext e join pg_statistic_ext_data d on d.stxoid = e.oid"
  echo "-- что даёт ndistinct по city+region --"
  $PG -tAc "select stxname||' -> '||stxdndistinct::text
            from pg_statistic_ext e join pg_statistic_ext_data d on d.stxoid = e.oid
            where stxname='st_customers_geo'"
} | tee "$DATA_DIR/statistics.txt"

echo "== 2. Перезамер набора =="
TAG=stats bash "$SCRIPT_DIR/02-baseline.sh"
