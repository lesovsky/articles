#!/bin/bash
# Вторая половина ответа: те же отказы, но клиент с сетевыми таймаутами.
#
# Матрица без таймаутов показала, что кластер переключается за ~20 с, а клиент
# при "тихих" отказах (изоляция, заморозка) не узнаёт об этом вообще: пакеты
# теряются молча, libpq ждёт бесконечно. tcp_user_timeout ограничивает время,
# которое ядро будет вслепую переспрашивать отправленные данные.
set -u
cd "$(dirname "$0")"
source ./lib.sh

EXTRA=${EXTRA:-"tcp_user_timeout=5000"}
REP=${1:-3}; shift || true
TYPES=${*:-"netcut sigstop reboot kill9"}

for t in $TYPES; do
  for r in $(seq 1 "$REP"); do
    NAME="$t-tut-r$r"
    [ -d "../data/runs/$NAME" ] && { echo "== $NAME уже есть"; continue; }
    wait_healthy 180 >/dev/null || { echo "!! кластер не здоров перед $NAME"; exit 1; }
    bash ./runexp.sh "$NAME" "$t" leader 15 60 "$EXTRA" || echo "!! $NAME с ошибкой"
    sleep 10
  done
done
echo "== серия с таймаутами пройдена =="
