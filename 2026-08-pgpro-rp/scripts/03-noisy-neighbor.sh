#!/bin/bash
# Сценарий 1: шумный сосед.
#
# OLTP-нагрузка роли app и аналитические запросы роли analyst на одном сервере.
# Три конфигурации:
#   base     — только OLTP, соседа нет (точка отсчёта);
#   flat     — сосед есть, приоритизации нет (у всех вес по умолчанию 4);
#   priority — сосед есть, app 8/8/8, analyst 1/1/1.
#
# Сосед крутит аналитические запросы в цикле всё время прогона, поэтому меряется
# не время одного запроса (под приоритизацией оно растянулось бы на десятки минут),
# а сколько проходов он успевает сделать. Это и есть цена, которую он платит.
#
# Тип нагрузки соседа задаётся первым аргументом:
#   io  (по умолчанию) — проход по таблице 13 ГБ, конкуренция с OLTP за диск;
#   cpu               — запрос по закешированной таблице, конкуренция за процессор.
# Разница принципиальная: если сосед и OLTP упираются в разные ресурсы,
# приоритизация соседа приложению почти ничего не даёт.
#
# OLTP работает в отдельной базе oltp (-s 100, помещается в кеш) в режиме только
# чтения (-S). Так сделано ради воспроизводимости: на большом датасете с записью
# пропускная способность скакала от 50 до 344 tps между одинаковыми прогонами
# из-за чекпойнтов, на -S разброс укладывается в 4%.
# Сосед работает в базе postgres, где лежат большая таблица и t20.
#
# Результат: data/noisy.csv (OLTP) и data/noisy-analyst.csv (сосед)
set -e
source "$(dirname "$0")/lib.sh"

KIND="${1:-io}"
DURATION=60
CLIENTS=8
RUNS=5
NEIGHBORS=2

case "$KIND" in
  io)  NEIGHBOR_QUERY="$IO_QUERY";  SUFFIX="" ;;
  cpu) NEIGHBOR_QUERY="$CPU_QUERY"; SUFFIX="-cpu" ;;
  *)   echo "использование: $0 [io|cpu]"; exit 1 ;;
esac
echo "== нагрузка соседа: $KIND =="

echo "config,run,tps,lat_avg_ms,lat_p95_ms,lat_p99_ms" > "$DATA_DIR/noisy${SUFFIX}.csv"
echo "config,run,session,queries_done"      > "$DATA_DIR/noisy-analyst${SUFFIX}.csv"

set_interval 1s

# прогрев: первый прогон pgbench всегда быстрее/медленнее остальных из-за
# холодного кеша и первого чекпойнта, поэтому один прогон выполняем вхолостую
echo "== прогрев =="
sudo -u postgres pgbench -U app -h /tmp -n -S -c $CLIENTS -j 4 -T 60 oltp >/dev/null 2>&1

# Планы применяются в КАЖДОЙ базе, где работают приоритизируемые сеансы:
# таблицы расширения — объекты базы данных. Если оставить базу oltp без планов,
# её сеансы получат NULL вместо плана, и приоритизация не сработает ни для них,
# ни для конкурирующего с ними соседа в базе postgres.
apply_plans() { # $1 = flat | priority
  local app_plan analyst_plan db
  if [ "$1" = flat ]; then
    app_plan=plan_4_4_4; analyst_plan=plan_4_4_4
  else
    app_plan=plan_8_8_8; analyst_plan=plan_1_1_1
  fi
  for db in postgres oltp; do
    sudo -u postgres psql -d "$db" -q \
      -c "select pgpro_rp_update_role_plan('app','$app_plan')" \
      -c "select pgpro_rp_update_role_plan('analyst','$analyst_plan')" \
      -c "select pgpro_rp_invalidate_cache()" >/dev/null
  done
}

# сосед: крутит аналитический запрос в цикле, пока не выйдет время
neighbor() { # $1 = номер сессии, $2 = config, $3 = run
  local n=0 deadline=$(( $(date +%s) + DURATION ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    $PSQL -U analyst -h /tmp -d postgres -qtA \
      -c "set statement_timeout='${DURATION}s'" \
      -c "$NEIGHBOR_QUERY" >/dev/null 2>&1 && n=$((n+1))
  done
  csv "noisy-analyst${SUFFIX}.csv" "$2" "$3" "$1" "$n"
  echo "    сосед #$1: проходов $n"
}

for config in base flat priority; do
  [ "$config" != base ] && apply_plans "$config"

  for run in $(seq 1 $RUNS); do
    echo "== $config, прогон $run =="

    if [ "$config" != base ]; then
      for s in $(seq 1 $NEIGHBORS); do neighbor "$s" "$config" "$run" & done
      sleep 3
    fi

    # -l пишет латентность каждой транзакции: только так считается честный перцентиль,
    # а не перцентиль посекундных средних из отчётов -P
    sudo rm -f /tmp/pgb_log.* 2>/dev/null || true
    OUT=$(sudo -u postgres pgbench -U app -h /tmp -n -S -l --log-prefix=/tmp/pgb_log \
            -c $CLIENTS -j 4 -T $DURATION oltp 2>&1)

    TPS=$(echo "$OUT" | awk '/^tps =/ {print $3; exit}')
    LAT=$(echo "$OUT" | awk '/^latency average/ {print $4}')
    # поле 3 в логе pgbench — время транзакции в микросекундах
    # LC_ALL=C обязателен: в русской локали awk печатает 132,864 и ломает CSV.
    # Перевод строки в printf обязателен: без него read вернёт 1 и set -e убьёт скрипт.
    read -r P95 P99 < <(sudo cat /tmp/pgb_log.* 2>/dev/null | awk '{print $3}' | sort -n \
       | LC_ALL=C awk '{a[NR]=$1} END {printf "%.3f %.3f\n", a[int(NR*0.95)]/1000, a[int(NR*0.99)]/1000}')

    csv "noisy${SUFFIX}.csv" "$config" "$run" "$TPS" "$LAT" "$P95" "$P99"
    echo "    OLTP: tps=$TPS lat_avg=${LAT}ms p95=${P95}ms p99=${P99}ms"

    wait
  done
done

# возвращаем нейтральные планы
apply_plans flat
echo "== Готово: $DATA_DIR/noisy${SUFFIX}.csv, $DATA_DIR/noisy-analyst${SUFFIX}.csv =="
