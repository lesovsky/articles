-- q7. Короткий OLTP-запрос, попадающий в индекс.
-- Планировщик здесь прав, улучшать нечего. Запрос нужен для обратного вопроса:
-- сколько стоит сам aqo на запросе, которому он не нужен.
select s.sale_id, s.amount, s.sale_ts
from fact_sales s
where s.customer_id = :customer_id
  and s.sale_ts >= :'since'::timestamptz
order by s.sale_ts desc
limit 100;
