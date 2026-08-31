#!/bin/bash
# Привести стенд в состояние, пригодное для замеров failover.
#  1. Погасить стек мониторинга PPEM (ест ресурсы, возвращается после перезагрузки).
#  2. Одинаковое логирование на всех узлах — фазы failover снимаются по меткам
#     времени из логов, формат должен совпадать, и файл не должен ротироваться
#     посреди серии.
# Запускать с рабочей машины.
set -e
cd "$(dirname "$0")"
source ./hosts.sh

MON="ppem-agent pgpro-otel-collector node_exporter process_exporter vector vmagent"

for h in $NODES; do
  echo "===== $h ====="
  n "$h" "sudo systemctl disable --now $MON >/dev/null 2>&1; true"
  ssh $SSH_OPTS pgpro@"$h" 'sudo -u postgres psql -q -X -v ON_ERROR_STOP=1 -f -' < normalize.sql
done
echo
echo "-- проверка --"
all 'sudo -u postgres psql -tAc "select current_setting(\$\$log_directory\$\$)||\$\$ | \$\$||current_setting(\$\$log_filename\$\$)||\$\$ | \$\$||current_setting(\$\$log_line_prefix\$\$)||\$\$ | tz=\$\$||current_setting(\$\$log_timezone\$\$)" 2>/dev/null || echo "postgres не запущен"'
