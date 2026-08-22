#!/bin/bash
# Ось ввода-вывода: session_ioread_weight.
#
# Планы plan_io_low и plan_io_high отличаются ТОЛЬКО весом чтения (1 против 8),
# вес CPU у обоих 4 — иначе эффект смешается с приоритизацией процессора.
#
# Нагрузка: полный проход по pgbench_accounts (13 ГБ) при 8 ГБ RAM и
# shared_buffers 1 ГБ. Страничный кеш сбрасывается перед каждым прогоном,
# то есть чтение действительно идёт с диска.
#
# Все четыре сеанса стартуют одновременно: два с весом чтения 1 и два с весом 8.
# Параллелизм выключен — иначе воркеры уводят запрос из-под приоритизации.
#
# Результат: data/io.csv
set -e
source "$(dirname "$0")/lib.sh"

ensure_default_group

echo "config,role,ioread_weight,run,duration_ms" > "$DATA_DIR/io.csv"
set_interval 1s

$PSQL -q -c "select pgpro_rp_update_role_plan('test_low','plan_io_low')" \
         -c "select pgpro_rp_update_role_plan('test_high','plan_io_high')" \
         -c "select pgpro_rp_invalidate_cache()" >/dev/null

drop_caches() {
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
  sleep 2
}

io_query() { # $1 = роль, $2 = файл для результата
  local s e
  s=$(date +%s%N)
  $PSQL -U "$1" -h /tmp -d postgres -tA \
    -c "set max_parallel_workers_per_gather=0" \
    -c "$IO_QUERY" >/dev/null
  e=$(date +%s%N)
  echo $(( (e-s)/1000000 )) > "$2"
}

echo "== контроль: один проход в одиночку, холодный кеш =="
for u in test_low test_high; do
  drop_caches
  io_query "$u" /tmp/io_solo
  w=1; [ "$u" = test_high ] && w=8
  csv io.csv solo "$u" "$w" 1 "$(cat /tmp/io_solo)"
  echo "  $u (ioread=$w): $(cat /tmp/io_solo) ms"
done

for run in 1 2 3; do
  echo "== одновременный прогон $run: 2 сеанса с весом 1 и 2 с весом 8 =="
  drop_caches
  io_query test_low  /tmp/io_l1 & p1=$!
  io_query test_low  /tmp/io_l2 & p2=$!
  io_query test_high /tmp/io_h1 & p3=$!
  io_query test_high /tmp/io_h2 & p4=$!
  wait $p1 $p2 $p3 $p4
  for f in /tmp/io_l1 /tmp/io_l2; do csv io.csv concurrent test_low  1 "$run" "$(cat $f)"; done
  for f in /tmp/io_h1 /tmp/io_h2; do csv io.csv concurrent test_high 8 "$run" "$(cat $f)"; done
  echo "  вес 1: $(cat /tmp/io_l1) / $(cat /tmp/io_l2) ms"
  echo "  вес 8: $(cat /tmp/io_h1) / $(cat /tmp/io_h2) ms"
done

# возвращаем исходные планы
$PSQL -q -c "select pgpro_rp_update_role_plan('test_low','plan_1_1_1')" \
         -c "select pgpro_rp_update_role_plan('test_high','plan_8_8_8')" \
         -c "select pgpro_rp_invalidate_cache()" >/dev/null
echo "== Готово: $DATA_DIR/io.csv =="
