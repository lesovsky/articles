#!/bin/bash
# Общие функции: определение лидера, проверка здоровья, восстановление кластера.
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SDIR/hosts.sh"

# psql на узле, tuples-only, без выравнивания
tq() { ssh $SSH_OPTS pgpro@"$1" 'sudo -u postgres psql -X -d biha_db -tAf -' ; }

# leader_ip — вернуть ip текущего лидера, опросив узлы по очереди
leader_ip() {
  local h lid
  for h in $PGNODES; do
    lid=$(echo "select leader_id from biha.status_v where id = (select current_setting('biha.id')::int);" | tq "$h" 2>/dev/null | tr -d ' ')
    [ -n "$lid" ] || continue
    case "$lid" in 1) echo $N1; return 0;; 2) echo $N2; return 0;; 3) echo $N3; return 0;; 4) echo $N4; return 0;; esac
  done
  return 1
}

# cluster_line — однострочная сводка состояния (для логов эксперимента)
cluster_line() {
  local h
  for h in $PGNODES; do
    echo "select string_agg(id||'='||state||'/'||online, ' ' order by id) from biha.status_v;" | tq "$h" 2>/dev/null && return 0
  done
  echo "ВСЕ УЗЛЫ НЕДОСТУПНЫ"
}

# healthy — один лидер, остальные обычные узлы фолловеры, все online.
# Число фолловеров считается по составу PGNODES, а не зашито: кластер по ходу
# работы переводился из трёх обычных узлов в схему «два узла + рефери».
healthy() {
  local s want
  s=$(cluster_line)
  want=$(( $(echo $PGNODES | wc -w) - 1 ))
  [ "$(echo "$s" | grep -o 'LEADER_RW' | wc -l)" = 1 ] &&
  [ "$(echo "$s" | grep -o 'FOLLOWER' | wc -l)" = "$want" ] &&
  ! echo "$s" | grep -q 'false'
}

# wait_healthy [timeout_s] — ждать восстановления кластера
wait_healthy() {
  local t=${1:-180} i=0
  while [ $i -lt "$t" ]; do
    healthy && { echo "кластер здоров через ${i}s: $(cluster_line)"; return 0; }
    sleep 3; i=$((i+3))
  done
  echo "НЕ восстановился за ${t}s: $(cluster_line)"; return 1
}
