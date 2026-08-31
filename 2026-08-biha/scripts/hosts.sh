#!/bin/bash
# Узлы стенда BiHA и хелпер для запуска команд на них.
# Подключается по ключу ~/.ssh/aiw-stand-ed25519 (раскладывается 00-access.sh).
KEY=~/.ssh/aiw-stand-ed25519
SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

N1=10.128.31.145
N2=10.128.30.128
N3=10.128.31.13
N4=10.128.30.212

# Состав кластера менялся по ходу работы, поэтому роли заданы явно.
#   PGNODES  — обычные узлы, к которым подключаются клиенты
#   MEMBERS  — все члены кластера (обычные + рефери): состояние, логи
#   LOAD     — узел с нагрузчиком и сборщиком, в кластер НЕ входит
# Схема 1 (посты 1–4): PGNODES="$N1 $N2 $N3", MEMBERS то же, LOAD=$N4
# Схема 2 (рефери):    PGNODES="$N1 $N2", MEMBERS="$N1 $N2 $N4", LOAD=$N3
PGNODES=${PGNODES:-"$N1 $N2"}
MEMBERS=${MEMBERS:-"$N1 $N2 $N4"}
LOAD=${LOAD:-$N3}

NODES="$N1 $N2 $N3 $N4"

# n <ip> <команда...> — выполнить команду на узле
n() { local h=$1; shift; ssh $SSH_OPTS pgpro@"$h" "$@"; }

# all <команда...> — выполнить на всех узлах с заголовком
all() { for h in $NODES; do echo "===== $h ====="; ssh $SSH_OPTS pgpro@"$h" "$@" 2>&1; done; }

# q <ip> — выполнить SQL, поданный на stdin, в biha_db на узле.
#   пример: echo "select * from biha.status_v;" | q $N1
q() { ssh $SSH_OPTS pgpro@"$1" 'sudo -u postgres psql -X -d biha_db -f -'; }
# qa — то же на всех узлах с заголовком (SQL читается один раз в переменную)
qa() { local sql; sql=$(cat); for h in $NODES; do echo "===== $h ====="; printf '%s' "$sql" | ssh $SSH_OPTS pgpro@"$h" 'sudo -u postgres psql -X -d biha_db -f -' 2>&1; done; }
