-- q6. GROUP BY по коррелированным ключам.
-- Число групп планировщик считает как произведение n_distinct по колонкам —
-- 200 * 20 = 4000 вместо фактических 200. Ошибка бьёт по выбору между
-- HashAggregate и GroupAggregate и по оценке нужной памяти.
select c.city, c.region, count(*) as cnt, sum(s.amount) as total
from fact_sales s
join customers c using (customer_id)
where s.sale_ts >= :'since'::timestamptz
group by 1, 2;
