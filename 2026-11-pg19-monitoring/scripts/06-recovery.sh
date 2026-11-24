#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
standby="$root/data/standby"
results="$root/data/results"
mkdir -p "$results"

if [[ ! -d $standby ]]; then
    psql -X -d pg19_monitoring -c "SELECT pg_drop_replication_slot('lab_standby') WHERE EXISTS (SELECT FROM pg_replication_slots WHERE slot_name = 'lab_standby')"
    /usr/lib/postgresql/19/bin/pg_basebackup --host=/var/run/postgresql --port=5432 --username=lesovsky --pgdata="$standby" --wal-method=stream --checkpoint=fast --create-slot --slot=lab_standby --no-password
    cat > "$standby/postgresql.conf" <<'EOF'
port = 55432
listen_addresses = ''
unix_socket_directories = '/tmp'
hot_standby = on
primary_conninfo = 'host=/var/run/postgresql port=5432 user=lesovsky dbname=pg19_monitoring application_name=lab_standby'
primary_slot_name = 'lab_standby'
EOF
    echo 'local all all trust' > "$standby/pg_hba.conf"
    touch "$standby/standby.signal"
fi
if ! /usr/lib/postgresql/19/bin/pg_ctl -D "$standby" status >/dev/null 2>&1; then
    /usr/lib/postgresql/19/bin/pg_ctl -D "$standby" -l "$results/recovery-standby-server.log" -w start
fi

standby_psql=(psql -X -h /tmp -p 55432 -d pg19_monitoring -v ON_ERROR_STOP=1)
for _ in $(seq 1 50); do
    if "${standby_psql[@]}" -Atqc "SELECT pg_is_in_recovery()" | grep -qx t; then
        break
    fi
    sleep 0.2
done

"${standby_psql[@]}" --csv -c "SELECT * FROM pg_stat_recovery" > "$results/recovery-before.csv"
"${standby_psql[@]}" -c "SELECT pg_wal_replay_pause()" >/dev/null
trap '"${standby_psql[@]}" -c "SELECT pg_wal_replay_resume()" >/dev/null 2>&1 || true' EXIT
psql -X -d pg19_monitoring -v ON_ERROR_STOP=1 -c "UPDATE lab.wal_lab SET payload = repeat('r', 200) WHERE id = 1; SELECT pg_switch_wal();" >/dev/null
sleep 1
"${standby_psql[@]}" --csv -c "SELECT * FROM pg_stat_recovery" > "$results/recovery-paused.csv"
"${standby_psql[@]}" --csv -c "SELECT status, receive_start_lsn, written_lsn, flushed_lsn, latest_end_lsn FROM pg_stat_wal_receiver" > "$results/recovery-wal-receiver.csv"
"${standby_psql[@]}" -c "SELECT pg_wal_replay_resume()" >/dev/null
trap - EXIT
sleep 1
"${standby_psql[@]}" --csv -c "SELECT * FROM pg_stat_recovery" > "$results/recovery-after.csv"
