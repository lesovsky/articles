#!/bin/bash
# Оркестратор одного прогона: поднимает нагрузчик и сборщик, вносит отказ,
# снимает его, собирает все артефакты в data/runs/<имя>/.
#
#   runexp.sh <имя> <тип отказа> <цель: leader|follower|ip> [pre_s] [post_s]
#
# pre_s  — сколько писать до отказа (нужен участок нормальной работы)
# post_s — сколько писать после отказа, до его снятия
set -u
cd "$(dirname "$0")"
source ./lib.sh

NAME=$1; TYPE=$2; TGT=$3; PRE=${4:-15}; POST=${5:-90}; CONN_EXTRA=${6:-}; QTO=${7:-0}; SC=${SC:-}
OUT=../data/runs/$NAME
HOSTS=$(echo $PGNODES | tr " " ",")
DUR=$((PRE + POST + 30))

echo "== $NAME: $TYPE на $TGT =="
# SKIP_HEALTH=1 — осознанный прогон в уже деградированном кластере
# (например: рефери погашен заранее, проверяем отказ лидера без него)
if [ "${SKIP_HEALTH:-0}" != "1" ]; then
  healthy || { echo "кластер не здоров, прогон отменён: $(cluster_line)"; exit 1; }
else
  echo "проверка здоровья пропущена намеренно: $(cluster_line)"
fi

LEADER=$(leader_ip)
case "$TGT" in
  leader)   HOST=$LEADER ;;
  follower) for h in $PGNODES; do [ "$h" != "$LEADER" ] && HOST=$h && break; done ;;
  *)        HOST=$TGT ;;
esac
echo "лидер сейчас: $LEADER, цель отказа: $HOST"

mkdir -p "$OUT"
n $LOAD "rm -f ~/stand/out/$NAME.*"

# метаданные прогона — без них цифры невоспроизводимы
{
  echo "name=$NAME"; echo "type=$TYPE"; echo "target=$TGT"; echo "target_ip=$HOST"
  echo "leader_before=$LEADER"; echo "pre_s=$PRE"; echo "post_s=$POST"
  echo "conn_extra=$CONN_EXTRA"
  echo "query_timeout=$QTO"
  echo "started_at=$(date -u +%FT%T.%NZ)"
  echo "state_before=$(cluster_line)"
  echo "synchronous_standby_names=$(echo "show synchronous_standby_names;" | tq $LEADER | tr -d ' ')"
  echo "--- biha.config() ---"
  echo "select id,nquorum,minnodes,heartbeat_send_period,heartbeat_max_lost,sync_standbys_min,service_mode from biha.config() where level=1 order by id;" | tq $LEADER
} > "$OUT/meta.txt"

# таблица чистится перед каждым прогоном: seq у нагрузчика начинается с 1,
# и остатки прошлого прогона ломали бы вставку по первичному ключу
echo "truncate hb;" | ssh $SSH_OPTS pgpro@$LEADER 'sudo -u postgres psql -X -q -d bihatest -f -'

# Нагрузчик и сборщик держатся открытыми ssh-сессиями в фоне НА ЭТОЙ машине:
# попытки отпустить процесс на удалённой стороне (nohup, setsid, -n) не
# освобождают ssh-канал, и скрипт блокировался на всю длительность прогона.
n $LOAD "cd ~/stand && python3 collector.py --hosts $HOSTS --duration $DUR --out out/$NAME.state" >/dev/null 2>&1 &
CPID=$!
n $LOAD "cd ~/stand && python3 writer.py --hosts $HOSTS --user bihatest --duration $DUR --conn-extra '$CONN_EXTRA' --query-timeout $QTO --sync-commit '$SC' --out out/$NAME" >/dev/null 2>&1 &
WPID=$!

# PIN=leader — второй нагрузчик, прибитый к текущему лидеру и без проверки
# read-write. Нужен для разделений сети: показывает, сколько ещё изолированный
# лидер принимает записи. Диапазон seq не пересекается с основным нагрузчиком.
if [ "${PIN:-}" = "leader" ]; then
  n $LOAD "cd ~/stand && python3 writer.py --hosts $LEADER --user bihatest --duration $DUR --no-rw-check --seq-start 10000000 --conn-extra '$CONN_EXTRA' --query-timeout $QTO --sync-commit '$SC' --out out/$NAME.pin" >/dev/null 2>&1 &
  PPID_W=$!
  echo "pinned_writer=$LEADER" >> "$OUT/meta.txt"
fi

sleep 2   # даём нагрузчику подключиться до начала отсчёта
sleep "$PRE"

bash ./inject.sh "$TYPE" "$HOST" | tee -a "$OUT/meta.txt"
sleep "$POST"
bash ./inject.sh "$TYPE" "$HOST" undo | tee -a "$OUT/meta.txt"

echo "ждём завершения нагрузчика и сборщика"
wait $WPID $CPID ${PPID_W:-}

{ echo "state_after=$(cluster_line)"; echo "finished_at=$(date -u +%FT%T.%NZ)"; } >> "$OUT/meta.txt"

# что реально осталось в базе после failover — вторая половина расчёта RPO
NEWLEADER=$(leader_ip)
echo "leader_after=$NEWLEADER" >> "$OUT/meta.txt"
echo "select seq from hb order by seq;" | ssh $SSH_OPTS pgpro@$NEWLEADER 'sudo -u postgres psql -X -tA -d bihatest -f -' > "$OUT/$NAME.stored" 2>/dev/null

scp $SSH_OPTS pgpro@$LOAD:"stand/out/$NAME.*" "$OUT/" >/dev/null 2>&1
for h in $MEMBERS; do
  n "$h" 'sudo sh -c "cat /var/lib/pgpro/ent-18/data/log/postgresql-*.log"' > "$OUT/pg-$h.log" 2>/dev/null
done
echo "артефакты: $OUT"
wait_healthy 240 | tee -a "$OUT/meta.txt"
