-- q2. Корреляция, видимая только через join.
-- Сегмент 'vip' — это 1 % клиентов, но 30 % продаж. Планировщик оценивает долю
-- клиентов, реальность определяется долей продаж. Расширенная статистика здесь
-- бессильна принципиально: корреляция лежит между таблицами, а не внутри одной.
select c.segment, count(*) as cnt, avg(s.amount) as avg_amount
from fact_sales s
join customers c using (customer_id)
where c.segment = :'segment'
group by 1;
