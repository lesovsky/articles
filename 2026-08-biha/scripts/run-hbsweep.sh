#!/bin/bash
# Развёртка по бюджету детекта — замена отсутствующей линейки.
#
# Матрица показала, что простой записи почти целиком состоит из ожидания
# heartbeat. Здесь проверяется, чем именно управляет админ: меняем
# heartbeat_send_period и heartbeat_max_lost и смотрим, как двигается простой.
#
# Клиент всегда с tcp_user_timeout — иначе меряли бы не кластер, а таймауты TCP.
set -u
cd "$(dirname "$0")"
source ./lib.sh

REP=${REP:-2}
EXTRA="tcp_user_timeout=5000"
# период_мс:потерь — бюджет детекта от 0.9 до 20 секунд
POINTS=${*:-"2000:10 1000:10 1000:5 500:5 300:3"}

for p in $POINTS; do
  PER=${p%%:*}; LOST=${p##*:}
  echo "== бюджет $((PER*LOST/1000))s: send_period=$PER max_lost=$LOST =="
  L=$(leader_ip)
  printf "select biha.set_heartbeat_send_period(%s);\nselect biha.set_heartbeat_max_lost(%s);\n" "$PER" "$LOST" | tq "$L" >/dev/null
  sleep 5
  echo -n "  применено: "
  echo "select distinct heartbeat_send_period||'/'||heartbeat_max_lost from biha.config() where level=1;" | tq "$L"
  for r in $(seq 1 "$REP"); do
    NAME="hb-${PER}-${LOST}-r$r"
    [ -d "../data/runs/$NAME" ] && { echo "  $NAME уже есть"; continue; }
    wait_healthy 180 >/dev/null || { echo "!! кластер не здоров перед $NAME"; exit 1; }
    bash ./runexp.sh "$NAME" kill9 leader 15 60 "$EXTRA" | grep -E 'INJECT|здоров|НЕ восст'
    sleep 10
  done
done
# вернуть дефолт
L=$(leader_ip)
printf "select biha.set_heartbeat_send_period(1000);\nselect biha.set_heartbeat_max_lost(10);\n" | tq "$L" >/dev/null
echo "== развёртка пройдена, параметры возвращены к дефолту =="
