-- Генерация справочников customers и products с УПРАВЛЯЕМОЙ корреляцией колонок.
--
-- Вызывается как:  psql -v corr=1.0 -f dim-gen.sql
--
-- :corr — доля строк, в которых связанная колонка определяется ведущей
--         (1.0 — жёсткая иерархия «город принадлежит региону», 0.0 — колонки
--         независимы). Это главная ручка эксперимента: сила ошибки планировщика
--         на коррелированных предикатах регулируется именно ей.
--
-- Справочники маленькие (2 млн и 200 тыс. строк), поэтому перегенерация с другим
-- corr занимает секунды и НЕ требует трогать fact_sales на 150 млн строк.

\set ON_ERROR_STOP on
\timing off

-- Детерминированный псевдослучайный источник: хеш от номера строки и «соли».
-- Возвращает 0 .. 2^31-1. Ничего не зависит от порядка выполнения и сессии.
create or replace function h(x bigint, salt int) returns bigint
language sql immutable parallel safe as
$$ select (hashint8(x * 1000003 + salt) & 2147483647)::bigint $$;

truncate customers;
truncate products;

-- customers: 2 млн.
--   city    — 200 значений
--   region  — 20 значений; при corr=1 город однозначно принадлежит региону
--   country — 5 значений; при corr=1 регион однозначно принадлежит стране
--
-- Планировщик перемножает селективности трёх предикатов и при corr=1
-- недооценивает результат примерно в 100 раз.
insert into customers (customer_id, city, region, country, segment, signup_date)
select
  i,
  'city_'    || lpad(city_id::text, 3, '0'),
  'region_'  || lpad(region_id::text, 2, '0'),
  'country_' || (region_id / 4)::text,
  -- Сегмент задан диапазоном id: доли клиентов 1 / 4 / 15 / 80 %.
  -- В fact_sales эти сегменты представлены совсем другими долями (см. 01-dataset.sh),
  -- что даёт корреляцию, проявляющуюся только через join.
  case when i <=  20000 then 'vip'
       when i <= 100000 then 'gold'
       when i <= 400000 then 'silver'
       else                  'mass' end,
  date '2020-01-01' + (h(i, 5) % 2000)::int
from (
  select
    i,
    (h(i, 1) % 200) as city_id,
    case when (h(i, 2) % 1000) < (:corr * 1000)::int
         then (h(i, 1) % 200) / 10          -- регион выводится из города
         else  h(i, 3) % 20                 -- регион независим
    end as region_id
  from generate_series(1, 2000000) i
) s;

-- products: 200 тыс.
--   category    — 50 значений
--   subcategory — 500 значений; при corr=1 подкатегория принадлежит категории
insert into products (product_id, category, subcategory, brand, supplier_id, price)
select
  i,
  'cat_'   || lpad(cat_id::text, 2, '0'),
  'subcat_'|| lpad(sub_id::text, 3, '0'),
  'brand_' || lpad((h(i, 11) % 2000)::text, 4, '0'),
  1 + (h(i, 12) % 500)::int,
  round((10 + h(i, 13) % 100000)::numeric / 100, 2)::float8
from (
  select
    i,
    (h(i, 10) % 500) as sub_id,
    case when (h(i, 14) % 1000) < (:corr * 1000)::int
         then (h(i, 10) % 500) / 10
         else  h(i, 15) % 50
    end as cat_id
  from generate_series(1, 200000) i
) s;

analyze customers;
analyze products;

select 'customers' as t, count(*) from customers
union all select 'products', count(*) from products;

-- Фактическая сила корреляции — для протокола эксперимента.
select
  :corr                                              as corr_param,
  count(distinct (city, region))                     as city_region_pairs,
  count(distinct city) * count(distinct region)      as pairs_if_independent
from customers;
