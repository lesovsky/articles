#!/bin/bash
# Генерация датасета: звезда fact_sales + customers / products / stores / suppliers.
#
# Датасет спроектирован так, чтобы планировщик ошибался в оценке кардинальности
# по шести разным причинам, и чтобы силу каждой ошибки можно было менять НЕ
# перегенерируя 150 млн строк:
#
#   1. коррелированные предикаты в одной таблице  -> ручка corr в dim-gen.sql
#   2. корреляция, видимая только через join      -> выбор сегмента в запросе
#   3. перекос частот за пределами MCV            -> выбор product_id в запросе
#   4. предикаты по выражениям                    -> сезонность sale_ts
#   5. цепочка из пяти join                       -> схема звезды
#   6. GROUP BY по коррелированным ключам         -> ручка corr
#
# Время генерации на стенде (8 vCPU): около 40 минут вместе с индексами.
set -e
source "$(dirname "$0")/lib.sh"

ROWS=${ROWS:-150000000}     # строк в fact_sales
CHUNKS=${CHUNKS:-6}         # параллельных процессов вставки
CORR=${CORR:-1.0}           # сила корреляции в справочниках

echo "== 1. Схема =="
$PG -q <<'SQL'
drop table if exists fact_sales, customers, products, stores, suppliers cascade;

create table stores (
  store_id  int primary key,
  city      text not null,
  region    text not null,
  country   text not null
);

create table suppliers (
  supplier_id int primary key,
  name        text not null,
  country     text not null
);

create table customers (
  customer_id int primary key,
  city        text not null,
  region      text not null,
  country     text not null,
  segment     text not null,
  signup_date date not null
);

create table products (
  product_id  int primary key,
  category    text not null,
  subcategory text not null,
  brand       text not null,
  supplier_id int not null,
  price       float8 not null
);

create table fact_sales (
  sale_id     bigint not null,
  customer_id int    not null,
  product_id  int    not null,
  store_id    int    not null,
  sale_ts     timestamptz not null,
  qty         int    not null,
  amount      float8 not null,
  status      smallint not null
);

-- Autovacuum на тестовых таблицах выключен намеренно: autoanalyze посреди серии
-- прогонов молча обновит статистику и сдвинет базовую линию, к которой мы
-- сравниваем aqo. Все analyze в экспериментах — только явные.
alter table fact_sales set (autovacuum_enabled = off, toast.autovacuum_enabled = off);
alter table customers  set (autovacuum_enabled = off);
alter table products   set (autovacuum_enabled = off);
alter table stores     set (autovacuum_enabled = off);
alter table suppliers  set (autovacuum_enabled = off);
SQL

echo "== 2. Малые справочники (stores, suppliers) =="
$PG -q <<'SQL'
create or replace function h(x bigint, salt int) returns bigint
language sql immutable parallel safe as
$$ select (hashint8(x * 1000003 + salt) & 2147483647)::bigint $$;

-- География магазинов иерархична всегда: город -> регион -> страна.
insert into stores
select i,
       'city_'    || lpad(((i-1) % 100)::text, 3, '0'),
       'region_'  || lpad((((i-1) % 100) / 5)::text, 2, '0'),
       'country_' || ((((i-1) % 100) / 5) / 4)::text
from generate_series(1, 1000) i;

insert into suppliers
select i, 'supplier_' || lpad(i::text, 3, '0'),
       'country_' || (h(i, 20) % 5)::text
from generate_series(1, 500) i;

analyze stores; analyze suppliers;
SQL

echo "== 3. Справочники с управляемой корреляцией (corr=$CORR) =="
$PSQL -d "$DB" -q -v corr="$CORR" -f "$(dirname "$0")/dim-gen.sql"

echo "== 4. fact_sales: $ROWS строк в $CHUNKS процессов =="
# Вставка идёт параллельно, но остаётся детерминированной: значение каждой
# строки — функция её номера, а не порядка вставки и не состояния сессии.
PER=$(( ROWS / CHUNKS ))
seq 0 $(( CHUNKS - 1 )) | xargs -P "$CHUNKS" -I{} bash -c "
  $PSQL -d $DB -q -c \"
    insert into fact_sales
    select
      i,
      -- customer_id: сегменты дают 30/25/25/20 % продаж при долях клиентов
      -- 1/4/15/80 %. Планировщик оценит долю клиентов, факт — долю продаж.
      case
        when h(i, 10) % 1000 <  300 then 1      + (h(i, 11) % 20000)::int
        when h(i, 10) % 1000 <  550 then 20001  + (h(i, 12) % 80000)::int
        when h(i, 10) % 1000 <  800 then 100001 + (h(i, 13) % 300000)::int
        else                             400001 + (h(i, 14) % 1600000)::int
      end,
      -- product_id: паретообразный перекос. Топ попадает в MCV, а длинный
      -- хвост планировщик усредняет — там и живут ошибки в обе стороны.
      1 + floor(199999 * power((h(i, 20) % 1000000)::float8 / 1000000, 3))::int,
      1 + (h(i, 30) % 1000)::int,
      -- sale_ts: три года со смещением объёма к концу периода плюс суточный
      -- профиль. Нужен для предикатов по выражениям (date_trunc, extract).
      timestamptz '2023-01-01 00:00:00+03'
        + (floor(1095 * power((h(i, 40) % 1000000)::float8 / 1000000, 0.7)) || ' days')::interval
        + ((28800 + h(i, 41) % 43200) || ' seconds')::interval,
      1 + (h(i, 50) % 10)::int,
      round(((10 + h(i, 51) % 100000)::numeric / 100), 2)::float8,
      -- status: 95 % единиц. Классический перекос, на котором планировщик
      -- ошибается в оценке редких значений.
      case when h(i, 52) % 100 < 95 then 1 else (2 + h(i, 53) % 4)::int end
    from generate_series({} * $PER + 1, ({} + 1) * $PER) i\"
"

echo "== 5. Индексы =="
$PG -q -c "set maintenance_work_mem='1GB'" \
       -c "set max_parallel_maintenance_workers=4" \
       -c "create index fact_sales_customer_idx on fact_sales(customer_id)" \
       -c "create index fact_sales_product_idx  on fact_sales(product_id)" \
       -c "create index fact_sales_ts_idx       on fact_sales(sale_ts)"

echo "== 6. ANALYZE =="
# default_statistics_target НЕ трогаем: в сборке Postgres Pro он равен 800
# (в postgresql.conf; boot_val ванильного PostgreSQL — 100). Это та статистика,
# с которой реально живут пользователи платформы, и постановка от этого строже:
# aqo должен показать пользу там, где не хватает уже расширенной выборки.
$PG -tAc "select 'default_statistics_target = '||setting||' (boot_val '||boot_val||')'
          from pg_settings where name='default_statistics_target'"
$PG -q -c "analyze fact_sales"

echo "== 7. Итог =="
{
  echo "# датасет, $(date -Iseconds); ROWS=$ROWS CORR=$CORR"
  $PG -tAc "select 'default_statistics_target = '||setting from pg_settings where name='default_statistics_target'"
  $PG -tAc "
    select t||' | '||to_char(n,'FM999,999,999')||' строк | '||pg_size_pretty(pg_total_relation_size(t::regclass))
    from (
      select 'fact_sales' t, count(*) n from fact_sales
      union all select 'customers', count(*) from customers
      union all select 'products',  count(*) from products
      union all select 'stores',    count(*) from stores
      union all select 'suppliers', count(*) from suppliers
    ) s order by pg_total_relation_size(t::regclass) desc"
  echo "-- итого --"
  $PG -tAc "select pg_size_pretty(pg_database_size('$DB'))"
  echo "-- доли сегментов: продажи против клиентов (механизм корреляции через join) --"
  $PG -tAc "
    with f as (select c.segment, count(*) n from fact_sales s join customers c using (customer_id) group by 1),
         c as (select segment, count(*) n from customers group by 1)
    select f.segment||' | продаж '||round(100.0*f.n/sum(f.n) over (),1)||'% | клиентов '
           ||round(100.0*c.n/sum(c.n) over (),1)||'%'
    from f join c using (segment) order by f.n desc"
} | tee "$DATA_DIR/dataset.txt"
