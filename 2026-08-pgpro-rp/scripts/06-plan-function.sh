#!/bin/bash
# Сценарий 4: своя логика выбора плана.
#
# pgpro_rp_set_plan_selection_function регистрирует функцию, которая вызывается
# при входе и возвращает идентификатор плана. Ловушка: пока не вызван
# pgpro_rp_invalidate_cache(), функция не вызывается вообще — применяется
# закешированный план роли.
#
# Результат (пишется через tee вызывающей стороной): data/plan-function.txt
set -e
source "$(dirname "$0")/lib.sh"
# вывод пишет вызывающая сторона: bash script | tee data/файл

echo "== Функция выбора плана: по application_name и времени суток =="
$PSQL -q <<'SQL'
CREATE OR REPLACE FUNCTION rp_select() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  app  text := current_setting('application_name', true);
  hour int  := extract(hour from now());
BEGIN
  -- выгрузки и отчёты всегда уступают дорогу
  IF app IN ('etl', 'bi', 'pg_dump') THEN
    RETURN pgpro_rp_get_plan_id_by_name('plan_1_1_1');
  END IF;

  -- ночью, когда OLTP-нагрузки нет, придушивать некого
  IF hour < 6 OR hour >= 22 THEN
    RETURN pgpro_rp_get_plan_id_by_name('plan_8_8_8');
  END IF;

  RETURN pgpro_rp_get_plan_id_by_name('plan_4_4_4');
END $$;
SQL

$PSQL -tAc "select pgpro_rp_set_plan_selection_function('rp_select')"
$PSQL -tAc "select pgpro_rp_get_plan_selection_function()" | sed 's/^/  зарегистрирована: /'

echo
echo "== БЕЗ invalidate_cache: функция не вызывается, действует план роли =="
for a in etl bi app; do
  w=$(sudo -u postgres PGAPPNAME=$a psql -U test_low -h /tmp -d postgres -tAc 'show session_cpu_weight')
  echo "  application_name=$a -> вес $w"
done

$PSQL -qtAc "select pgpro_rp_invalidate_cache()" >/dev/null
echo
echo "== ПОСЛЕ invalidate_cache: функция вызывается на каждый вход =="
for a in etl bi app etl app; do
  w=$(sudo -u postgres PGAPPNAME=$a psql -U test_low -h /tmp -d postgres -tAc 'show session_cpu_weight')
  echo "  application_name=$a -> вес $w"
done

echo
echo "== Снимаем функцию =="
$PSQL -tAc "select pgpro_rp_set_plan_selection_function(NULL)"
$PSQL -qtAc "select pgpro_rp_invalidate_cache()" >/dev/null
w=$(sudo -u postgres PGAPPNAME=etl psql -U test_low -h /tmp -d postgres -tAc 'show session_cpu_weight')
echo "  application_name=etl -> вес $w (снова план роли)"
echo "== Готово =="
