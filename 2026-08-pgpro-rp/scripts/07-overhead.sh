#!/bin/bash
# Секция «сколько стоит наблюдение».
#
# usage_tracking_interval — параметр с двусторонним компромиссом:
#   маленькое значение — чаще собирается статистика (накладные расходы),
#                        но приоритизация включается быстрее;
#   большое значение   — расходов меньше, но короткие запросы под неё не попадают.
#
# Здесь меряем ЦЕНУ: пропускную способность OLTP без соседа при разных значениях
# интервала. Обратная сторона — с какой длительности запроса приоритизация вообще
# начинает работать — меряется отдельно в 02-interval.sh.
#
# Результат: data/overhead.csv
set -e
source "$(dirname "$0")/lib.sh"

echo "interval,metric,run,value" > "$DATA_DIR/overhead.csv"

# Прогрев обязателен: предыдущие эксперименты вытесняют базу oltp из страничного
# кеша, и первые прогоны дают сотни tps вместо десятков тысяч.
echo "== прогрев =="
for i in 1 2; do
  sudo -u postgres pgbench -U app -h /tmp -n -S -c 8 -j 4 -T 60 oltp >/dev/null 2>&1
done

for interval in 0 1s 5s 30s 60s; do
  set_interval "$interval"
  echo "== usage_tracking_interval = $interval =="

  # (1) цена: чистый OLTP без соседа, 60 секунд, 8 клиентов.
  # Режим только чтения и база oltp — та же стабильная конфигурация, что в 03:
  # на записи по датасету 13 ГБ разброс между прогонами достигает семи раз и
  # накладные расходы в единицы процентов в нём просто не видны.
  for run in 1 2 3; do
    TPS=$(sudo -u postgres pgbench -U app -h /tmp -n -S -c 8 -j 4 -T 60 oltp 2>&1 \
            | awk '/^tps =/ {print $3; exit}')
    csv overhead.csv "$interval" tps "$run" "$TPS"
    echo "  tps прогон$run: $TPS"
  done

done

echo
echo "== вторая фаза: 200 соединений =="
# Восемь сеансов — слабая проверка для механизма, который на каждом такте обходит
# все активные бэкенды. max_connections на стенде поднят до 300 отдельно, заранее.
if [ "$($PSQL -tAc 'show max_connections')" -lt 220 ]; then
  echo "  пропущено: max_connections < 220, поднимите и перезапустите сервер"
else
  sudo -u postgres pgbench -U app -h /tmp -n -S -c 200 -j 4 -T 60 oltp >/dev/null 2>&1
  for interval in 0 1s; do
    set_interval "$interval"
    for run in 1 2 3; do
      TPS=$(sudo -u postgres pgbench -U app -h /tmp -n -S -c 200 -j 4 -T 60 oltp 2>&1 \
              | awk '/^tps =/ {print $3; exit}')
      csv overhead.csv "$interval" tps_200conn "$run" "$TPS"
      echo "  interval=$interval прогон$run: $TPS"
    done
  done
fi

set_interval 1s
echo "== Готово: $DATA_DIR/overhead.csv =="
