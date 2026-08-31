#!/bin/bash
# Общие переменные и функции экспериментов с aqo.
#
# Принцип стенда: все случайные величины датасета детерминированы — вместо
# random() везде используется хеш от номера строки. Датасет воспроизводится
# побайтово, в том числе при параллельной генерации в несколько процессов.

# psql запускается от пользователя стенда, а не через sudo: psql читает файлы
# прогонов и пишет планы правами КЛИЕНТА, и при sudo -u postgres он не мог
# прочитать каталог mktemp -d (права 700 у владельца). Роль pgpro заведена
# в 00-setup.sh.
PSQL="psql"
DB="aqotest"
PG="$PSQL -d $DB"
SERVICE="postgrespro-ent-18"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/../data"
QUERY_DIR="$SCRIPT_DIR/queries"
mkdir -p "$DATA_DIR" "$QUERY_DIR"
DATA_DIR="$(cd "$DATA_DIR" && pwd)"
