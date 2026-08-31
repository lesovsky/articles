#!/bin/bash
# Дозабрать логи для прогонов, где они оказались пустыми.
# Причина: ротация логов выключена, файл на узлах называется по дате старта
# сервера, а runexp.sh подставлял сегодняшнюю дату.
set -u
cd "$(dirname "$0")"
source ./lib.sh
for d in ../data/runs/*/; do
  s=$(cat "$d"/pg-*.log 2>/dev/null | wc -c)
  [ "$s" -ge 1000 ] && continue
  echo -n "$(basename "$d"): "
  for h in $N1 $N2 $N3; do
    n "$h" 'sudo sh -c "cat /var/lib/pgpro/ent-18/data/log/postgresql-*.log"' > "$d/pg-$h.log" 2>/dev/null
  done
  echo "$(cat "$d"/pg-*.log | wc -c) байт"
done
