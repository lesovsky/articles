-- q3. Перекос частот за пределами MCV.
-- Распределение product_id паретообразное. Топ уходит в MCV и оценивается точно,
-- а для хвоста планировщик берёт среднюю частоту (1 - sum(MCV)) / n_distinct,
-- которая отличается от фактической на порядки — в обе стороны.
select count(*) as cnt, sum(s.qty) as qty
from fact_sales s
where s.product_id = :product_id;
