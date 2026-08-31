-- q4. Предикаты по выражениям.
-- Для date_trunc() и extract() статистики нет вовсе: планировщик подставляет
-- фиксированные константы селективности независимо от данных.
select count(*) as cnt, sum(s.amount) as total
from fact_sales s
where date_trunc('month', s.sale_ts) = :'month'::timestamptz
  and extract(hour from s.sale_ts) between 9 and 11;
