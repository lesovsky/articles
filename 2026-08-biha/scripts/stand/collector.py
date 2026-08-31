#!/usr/bin/env python3
"""Сборщик состояния кластера: вторая шкала времени.

Опрашивает biha.status_v на каждом узле отдельно, коротким таймаутом, и пишет
всё в один CSV с единой меткой времени. Нужен, чтобы сопоставить «что кластер
говорит о себе» с «что видит клиент» (writer.py).

Опрос каждого узла отдельный и независимый: во время failover часть узлов не
отвечает, и это само по себе данные.
"""
import argparse, time, signal
import psycopg2

STOP = False
def _stop(*_):
    global STOP
    STOP = True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--hosts', required=True)
    ap.add_argument('--port', default='5432')
    ap.add_argument('--interval', type=float, default=0.25)
    ap.add_argument('--duration', type=float, default=120)
    ap.add_argument('--dbname', default='biha_db')
    ap.add_argument('--user', default='bihatest')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    signal.signal(signal.SIGINT, _stop); signal.signal(signal.SIGTERM, _stop)

    hosts = a.hosts.split(',')
    out = open(a.out, 'a', buffering=1)
    t0 = time.monotonic()
    while not STOP and (time.monotonic() - t0) < a.duration:
        tick = time.time()
        for h in hosts:
            try:
                c = psycopg2.connect(f"host={h} port={a.port} dbname={a.dbname} user={a.user} "
                                     f"connect_timeout=1 options='-c statement_timeout=800'")
                c.autocommit = True
                cur = c.cursor()
                cur.execute("select id, leader_id, term, online, state, "
                            "extract(epoch from since_last_hb) from biha.status_v")
                rows = cur.fetchall()
                me = None
                cur.execute("select current_setting('biha.id', true)")
                me = cur.fetchone()[0]
                for r in rows:
                    out.write(f"{tick:.3f},{h},{me},{r[0]},{r[1]},{r[2]},{r[3]},{r[4]},{r[5]}\n")
                c.close()
            except Exception as e:
                out.write(f"{tick:.3f},{h},,,,,,UNREACHABLE,{str(e).splitlines()[0].replace(',',';')[:80]}\n")
        d = a.interval - (time.time() - tick)
        if d > 0:
            time.sleep(d)
    out.close()

if __name__ == '__main__':
    main()
