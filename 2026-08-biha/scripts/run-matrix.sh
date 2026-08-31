#!/bin/bash
# Матрица поста 1: тип отказа × повторы, всегда по лидеру.
# Между прогонами кластер обязан вернуться в здоровое состояние — иначе
# следующий прогон меряет не то, что задумано, и серия останавливается.
#
#   run-matrix.sh <повторов> [типы отказа...]
set -u
cd "$(dirname "$0")"
source ./lib.sh

REP=${1:-3}; shift || true
TYPES=${*:-"stop kill9 reboot netcut sigstop"}

for t in $TYPES; do
  for r in $(seq 1 "$REP"); do
    NAME="$t-leader-r$r"
    if [ -d "../data/runs/$NAME" ]; then echo "== $NAME уже есть, пропускаю"; continue; fi
    if ! wait_healthy 180 >/dev/null; then
      echo "!! кластер не здоров перед $NAME: $(cluster_line) — серия остановлена"; exit 1
    fi
    bash ./runexp.sh "$NAME" "$t" leader 15 60 || echo "!! $NAME завершился с ошибкой"
    sleep 10
  done
done
echo "== матрица пройдена =="
