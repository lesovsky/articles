-- q8. Комбинированный аналитический запрос.
-- Коррелированные предикаты в customers плюс фильтр по категории товара.
-- Диапазон по времени убран намеренно: вместе с ним предикаты складывались
-- слишком селективно, планировщик попадал точно (ошибка 2x, время 3 мс) и
-- запрос переставал что-либо проверять.
select p.category, c.segment, count(*) as cnt, sum(s.amount) as total, avg(s.qty) as avg_qty
from fact_sales s
join customers c using (customer_id)
join products  p using (product_id)
where c.city = :'city' and c.region = :'region'
  and p.category = :'category'
group by 1, 2
order by 4 desc;
