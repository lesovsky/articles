-- q1. Коррелированные предикаты в одной таблице.
-- city -> region -> country: планировщик перемножает три селективности и
-- недооценивает выборку из customers примерно в 100 раз. Недооценка поднимается
-- в join с fact_sales и меняет выбор способа соединения.
select count(*) as cnt, sum(s.amount) as total
from fact_sales s
join customers c using (customer_id)
where c.city = :'city' and c.region = :'region' and c.country = :'country';
