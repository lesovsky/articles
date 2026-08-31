#!/bin/bash
# Разложить ssh-ключ на узлы стенда. Запускать один раз, с рабочей машины.
# Пароль пользователя pgpro передаётся через sshpass.
set -e
cd "$(dirname "$0")"
source ./hosts.sh
: "${STAND_PASS:=pgpro}"
for h in $NODES; do
  sshpass -p "$STAND_PASS" ssh-copy-id -i "$KEY.pub" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    pgpro@"$h" >/dev/null 2>&1 && echo "$h: ключ разложен" || echo "$h: ОШИБКА"
done
