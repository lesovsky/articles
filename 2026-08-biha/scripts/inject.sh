#!/bin/bash
# Инжектор отказов. Запускается с рабочей машины: inject.sh <тип> <ip> [do|undo]
#
# Метка времени снимается ЧАСАМИ САМОГО УЗЛА, в одной удалённой команде с
# действием. Часы рабочей машины расходятся с узлами почти на две секунды, а
# клиентский секундомер живёт на узле 4 — метка обязана быть в том же временном
# домене, иначе фазы не сходятся. Узлы между собой согласованы в пределах 40 мс.
#
# Типы:
#   stop      штатная остановка сервера        (соединения рвутся явно)
#   kill9     kill -9 всем процессам postgres  (соединения рвутся явно)
#   reboot    sysrq-перезагрузка узла          (соединения не рвутся)
#   netcut    DROP на портах 5432/5433 (nft)   (соединения не рвутся)
#   sigstop   SIGSTOP всем процессам postgres  (соединения не рвутся)
set -u
cd "$(dirname "$0")"  # скрипт, не source
source ./hosts.sh

TYPE=$1; HOST=$2; ACT=${3:-do}
SVC=postgrespro-ent-18
PORTS="5432, 5433"

NFT_ADD="sudo nft -f - <<'NFT'
table inet biha_cut {
  chain input {
    type filter hook input priority -100; policy accept;
    tcp dport { $PORTS } drop
    tcp sport { $PORTS } drop
  }
  chain output {
    type filter hook output priority -100; policy accept;
    tcp dport { $PORTS } drop
    tcp sport { $PORTS } drop
  }
}
NFT"

# id узла, на который переключаем лидерство: первый обычный узел, кроме цели
TARGET_ID=""
for h in $PGNODES; do
  [ "$h" = "$HOST" ] && continue
  case "$h" in "$N1") TARGET_ID=1;; "$N2") TARGET_ID=2;; "$N3") TARGET_ID=3;; esac
  break
done

# соседи по кластеру — все члены, кроме цели
PEERS=$(for h in $MEMBERS; do [ "$h" != "$HOST" ] && printf '%s, ' "$h"; done | sed 's/, $//')

# PEER=<ip> — отрезать цель только от одного конкретного соседа.
# Нужен для схемы с рефери: лидер теряет связь с фолловером, но продолжает
# видеть рефери, и наоборот. Полная изоляция такой случай не воспроизводит.
NFT_SPLIT="sudo nft -f - <<'NFT'
table inet biha_split {
  chain input {
    type filter hook input priority -100; policy accept;
    ip saddr { ${PEER:-0.0.0.0} } drop
  }
  chain output {
    type filter hook output priority -100; policy accept;
    ip daddr { ${PEER:-0.0.0.0} } drop
  }
}
NFT"
NFT_PART="sudo nft -f - <<'NFT'
table inet biha_part {
  chain input {
    type filter hook input priority -100; policy accept;
    ip saddr { $PEERS } drop
  }
  chain output {
    type filter hook output priority -100; policy accept;
    ip daddr { $PEERS } drop
  }
}
NFT"

# fire <удалённая команда> — снять метку часами узла и сразу выполнить действие
fire() {
  local ts
  # действие идёт отдельной строкой: у netcut внутри heredoc, и любая обёртка
  # в фигурные скобки ломает его терминатор
  ts=$(n "$HOST" "date +%s.%N
$1" 2>/dev/null | head -1)
  printf 'INJECT %s %s %s %s\n' "$TYPE" "$HOST" "$ACT" "$ts"
}

case "$TYPE:$ACT" in
  stop:do)     fire "sudo systemctl stop $SVC" ;;
  stop:undo)   fire "sudo systemctl start $SVC" ;;

  kill9:do)    fire "sudo pkill -9 -x postgres" ;;
  kill9:undo)  fire "sudo systemctl start $SVC" ;;

  # sysrq-b: перезагрузка без сброса кешей на диск. ssh обрывается — это норма,
  # поэтому команда сначала печатает метку, потом уходит в фон с задержкой.
  reboot:do)   fire "sudo sh -c 'nohup sh -c \"sleep 0.5; echo b > /proc/sysrq-trigger\" &'" ;;
  reboot:undo) echo "# узел поднимается сам, ждём ssh" >&2
               until n "$HOST" true 2>/dev/null; do sleep 2; done
               fire "true" ;;

  netcut:do)   fire "$NFT_ADD" ;;
  netcut:undo) fire "sudo nft delete table inet biha_cut" ;;

  # netpart: узел отрезан ТОЛЬКО от других узлов кластера, клиенты его видят.
  # Это и есть модель разделения сети, в которой возможен split-brain:
  # лидер теряет кворум, но продолжает быть доступен приложению.
  netsplit:do)   fire "$NFT_SPLIT" ;;
  netsplit:undo) fire "sudo nft delete table inet biha_split" ;;

  netpart:do)   fire "$NFT_PART" ;;
  netpart:undo) fire "sudo nft delete table inet biha_part" ;;

  # Плановое переключение лидера — не отказ, а штатная операция. Мерим тем же
  # прибором: сколько при этом не проходит запись у приложения.
  switchover:do)   fire "sudo -u postgres psql -X -d biha_db -tAc \"select biha.set_leader($TARGET_ID)\"" ;;
  switchover:undo) fire "true" ;;

  # Сервисный режим: узел выводится из кворума для плановых работ.
  service:do)   fire "sudo -u postgres psql -X -d biha_db -tAc \"select biha.service_mode(true)\"" ;;
  service:undo) fire "sudo -u postgres psql -X -d biha_db -tAc \"select biha.service_mode(false)\"" ;;

  sigstop:do)   fire "sudo pkill -STOP -x postgres" ;;
  sigstop:undo) fire "sudo pkill -CONT -x postgres" ;;

  *) echo "неизвестно: $TYPE:$ACT" >&2; exit 2 ;;
esac
