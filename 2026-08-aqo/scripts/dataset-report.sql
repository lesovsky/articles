-- Отчёт по сгенерированному датасету: размеры и проверка того, что механизмы
-- ошибок планировщика действительно заложены в данные.
\pset tuples_only on
\pset format unaligned

select 'default_statistics_target = '||setting from pg_settings where name='default_statistics_target';

select t||' | '||to_char(n,'FM999,999,999')||' строк | '||pg_size_pretty(pg_total_relation_size(t::regclass))
from (
  select 'fact_sales' as t, count(*) as n from fact_sales
  union all select 'customers', count(*) from customers
  union all select 'products',  count(*) from products
  union all select 'stores',    count(*) from stores
  union all select 'suppliers', count(*) from suppliers
) s order by pg_total_relation_size(t::regclass) desc;

select 'база целиком | '||pg_size_pretty(pg_database_size(current_database()));

-- Механизм 2: корреляция через join. Доля продаж сегмента должна заметно
-- расходиться с долей клиентов — иначе планировщику неоткуда ошибаться.
select 'сегмент '||f.segment||' | продаж '||round(100.0*f.n/sum(f.n) over (),1)
       ||'% | клиентов '||round(100.0*c.n/sum(c.n) over (),1)||'%'
from (select c.segment, count(*) n from fact_sales s join customers c using (customer_id) group by 1) f
join (select segment, count(*) n from customers group by 1) c using (segment)
order by f.n desc;

-- Механизм 1: корреляция внутри таблицы. Пар city+region должно быть ровно
-- столько, сколько городов, а не произведение мощностей.
select 'пар city+region: '||count(distinct (city, region))
       ||' против '||(count(distinct city) * count(distinct region))||' при независимости'
from customers;
