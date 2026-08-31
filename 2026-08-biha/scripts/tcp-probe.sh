#!/bin/bash
# Прямое наблюдение за TCP-сокетом клиента при двух видах отказа сервера.
#
# Статья утверждала, что при заморозке процессов ядро узла продолжает
# подтверждать пакеты, поэтому tcp_user_timeout не срабатывает. Это было
# выводом из косвенного признака (ошибок нет), а не наблюдением. Здесь оно
# проверяется напрямую: смотрим unacked и retrans в ss -ti со стороны клиента.
set -u
cd "$(dirname "$0")"
source ./lib.sh

L=$(leader_ip)
MODE=$1              # sigstop | netcut
DUR=${2:-24}

echo "== $MODE, лидер $L =="
n $LOAD "cd ~/stand && python3 writer.py --hosts $L --user bihatest --duration $((DUR+20)) \
  --no-rw-check --seq-start 30000000 \
  --out out/tcpprobe-$MODE" >/dev/null 2>&1 &
WP=$!
sleep 4

echo "-- до отказа --"
n $LOAD "ss -tin dst $L:5432 2>/dev/null | tr -s ' \\n' ' '" | cut -c1-260 || echo "(сокета нет)"

bash ./inject.sh "$MODE" "$L"
for i in $(seq 1 6); do
  sleep 3
  echo "-- T+$((i*3))s --"
  n $LOAD "ss -tin dst $L:5432 2>/dev/null | tr -s ' \\n' ' '" | cut -c1-260 || echo "(сокета нет)"
  echo
done
bash ./inject.sh "$MODE" "$L" undo
wait $WP 2>/dev/null
echo "-- ошибки клиента --"
n $LOAD "grep -c ',err,' stand/out/tcpprobe-$MODE.events || true"
