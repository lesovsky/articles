-- q5. Цепочка из пяти таблиц.
-- Ошибка оценки не остаётся локальной: она перемножается по мере подъёма по
-- дереву плана, и к верхним соединениям расхождение становится максимальным.
select st.region, p.category, count(*) as cnt, sum(s.amount) as total
from fact_sales s
join customers  c   using (customer_id)
join products   p   using (product_id)
join stores     st  using (store_id)
join suppliers  sup on sup.supplier_id = p.supplier_id
where c.segment = :'segment'
  and c.region = :'region'
  and p.category = :'category'
  and sup.country = :'country'
  and s.sale_ts >= :'since'::timestamptz
group by 1, 2;
