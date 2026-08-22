#!/bin/bash
# Общие функции для экспериментов.
#
# Важное правило стенда: любая фоновая нагрузка обязана самостоятельно завершиться.
# Без statement_timeout один оборванный прогон оставляет сессии, которые доедают
# все ядра, и машина перестаёт принимать даже ssh-подключения (проверено на себе).

PSQL="sudo -u postgres psql"
DATA_DIR="$(dirname "$0")/../data"
mkdir -p "$DATA_DIR"

# Запрос, упирающийся в CPU: около 7 секунд на свободном стенде.
CPU_QUERY="select count(*) from t20 where aid < 10000000 and md5(aid::text) = 'нет-такого'"

# Запрос, упирающийся в диск: полный проход по таблице 13 GB при 7 GB RAM.
IO_QUERY="select count(*) from pgbench_accounts where abalance = -999"

# timed_query РОЛЬ ЗАПРОС [WORKERS] -> длительность в миллисекундах
timed_query() {
  local role="$1" query="$2" workers="${3:-0}" s e
  s=$(date +%s%N)
  $PSQL -U "$role" -h /tmp -d postgres -tA \
    -c "set max_parallel_workers_per_gather=$workers" \
    -c 'set parallel_setup_cost=0' \
    -c 'set parallel_tuple_cost=0' \
    -c 'set min_parallel_table_scan_size=0' \
    -c "$query" >/dev/null
  e=$(date +%s%N)
  echo $(( (e-s)/1000000 ))
}

# pair_query ЗАПРОС [WORKERS] -> "мс_вес1 мс_вес8"
#
# Оба веса меряются ОДНОВРЕМЕННО. Это принципиально: если мерить последовательно,
# придушенный запрос идёт в разы дольше, фоновая нагрузка успевает завершиться по
# statement_timeout, и запрос с высоким весом меряется уже на свободной машине.
# Так получается красивая, но неверная разница в 13 раз вместо честных 1.5.
pair_query() {
  local query="$1" workers="${2:-0}"
  local f_low f_high
  f_low=$(mktemp); f_high=$(mktemp)
  ( timed_query test_low  "$query" "$workers" > "$f_low"  ) &
  local p_low=$!
  ( timed_query test_high "$query" "$workers" > "$f_high" ) &
  local p_high=$!
  wait $p_low $p_high
  echo "$(cat "$f_low") $(cat "$f_high")"
  rm -f "$f_low" "$f_high"
}

# burn_start РОЛЬ КОЛИЧЕСТВО [СЕКУНД] — фоновая CPU-нагрузка, гарантированно
# умирающая по statement_timeout. Значение таймаута должно с запасом перекрывать
# самый долгий замер в прогоне, иначе нагрузка исчезнет посреди измерения.
burn_start() {
  local role="$1" n="$2" limit="${3:-180}" i
  for ((i=0; i<n; i++)); do
    $PSQL -U "$role" -h /tmp -d postgres -qtA \
      -c "set statement_timeout='${limit}s'" \
      -c 'select count(*) from generate_series(1,2000000000)' >/dev/null 2>&1 &
  done
  sleep 3
}

burn_stop() {
  $PSQL -qtAc "select pg_terminate_backend(pid)
                 from pg_stat_activity
                where usename in ('test_low','test_high')
                  and pid <> pg_backend_pid()" >/dev/null 2>&1
  wait 2>/dev/null
  sleep 1
}

# Активная группа назначений — глобальное состояние кластера, и 04-daynight.sh
# её переключает. Если этого не проверять, все последующие замеры молча меряют
# отсутствие приоритизации: в чужой группе у ролей просто нет планов, и они
# получают дефолтную четвёрку. Проверено на себе — два прогона в мусор.
ensure_default_group() {
  local g
  g=$($PSQL -tAc "select pgpro_rp_get_active_group()")
  if [ "$g" != "default" ]; then
    echo "  (активная группа была '$g', возвращаю 'default')"
    $PSQL -qtAc "call pgpro_rp_set_active_group('default')" >/dev/null
  fi
  $PSQL -qtAc "select pgpro_rp_invalidate_cache()" >/dev/null
  # контроль: веса синтетических ролей должны различаться
  local wl wh
  wl=$($PSQL -U test_low  -h /tmp -d postgres -tAc 'show session_cpu_weight')
  wh=$($PSQL -U test_high -h /tmp -d postgres -tAc 'show session_cpu_weight')
  if [ "$wl" = "$wh" ]; then
    echo "ОШИБКА: test_low и test_high имеют одинаковый вес ($wl) — приоритизировать нечего" >&2
    exit 1
  fi
}

set_interval() {
  $PSQL -qtAc "alter system set usage_tracking_interval='$1'" >/dev/null
  $PSQL -qtAc "select pg_reload_conf()" >/dev/null
  sleep 2
}

# csv ФАЙЛ ПОЛЯ... — дописать строку в data/ФАЙЛ
csv() {
  local f="$DATA_DIR/$1"; shift
  local IFS=,
  echo "$*" >> "$f"
}

trap 'burn_stop' EXIT
