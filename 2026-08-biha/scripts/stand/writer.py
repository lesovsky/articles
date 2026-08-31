#!/usr/bin/env python3
"""Клиентский секундомер: пишет в кластер BiHA и фиксирует, когда запись пропала
и когда вернулась.

Главный прибор серии. Меряет то, что видит приложение, а не то, что кластер
сообщает о себе. Подключается так, как это делал бы обычный клиент без прокси:
libpq со списком всех узлов и target_session_attrs=read-write.

Пишет два файла:
  <out>.events  — события (ok/err/connect) с монотонной и настенной меткой
  <out>.acked   — seq всех подтверждённых сервером вставок (для расчёта RPO)

Оба формата — CSV без заголовка, чтобы дописывались построчно и переживали
падение самого нагрузчика.
"""
import argparse, os, sys, time, signal, threading
import psycopg2

STOP = False
def _stop(*_):
    global STOP
    STOP = True

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--hosts', required=True, help='список узлов через запятую')
    ap.add_argument('--port', default='5432')
    ap.add_argument('--dbname', default='bihatest')
    ap.add_argument('--user', default='postgres')
    ap.add_argument('--connect-timeout', default='2')
    ap.add_argument('--duration', type=float, default=120)
    ap.add_argument('--retry-sleep', type=float, default=0.02)
    ap.add_argument('--conn-extra', default='', help='добавка в строку подключения')
    ap.add_argument('--sync-commit', default='',
                    help='значение synchronous_commit для сессии (например local): '
                         'контроль, отделяющий ожидание синхронной репликации от прочего')
    ap.add_argument('--seq-start', type=int, default=0,
                    help='начало нумерации; двум нагрузчикам в одном прогоне '
                         'нужны непересекающиеся диапазоны')
    ap.add_argument('--no-rw-check', action='store_true',
                    help='не требовать read-write: клиент прибит к конкретному узлу '
                         'и пишет туда, пока тот соглашается принимать запись')
    ap.add_argument('--query-timeout', type=float, default=0,
                    help='прикладной дедлайн на запрос, с; 0 — без него. '
                         'Против замороженного сервера сетевые таймауты не '
                         'работают: ядро подтверждает пакеты, отвечать некому.')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    tsa = '' if a.no_rw_check else 'target_session_attrs=read-write '
    dsn = (f"host={a.hosts} port={a.port} dbname={a.dbname} user={a.user} "
           f"{tsa}connect_timeout={a.connect_timeout} "
           f"{a.conn_extra}")

    ev = open(a.out + '.events', 'a', buffering=1)
    ak = open(a.out + '.acked', 'a', buffering=1)

    t0 = time.monotonic()
    def log(kind, detail=''):
        ev.write(f"{time.time():.6f},{time.monotonic()-t0:.6f},{kind},{detail}\n")

    seq = a.seq_start
    conn = None
    cur = None
    log('run_start', dsn.replace(',', ';'))

    while not STOP and (time.monotonic() - t0) < a.duration:
        if conn is None:
            log('connect_start')
            try:
                conn = psycopg2.connect(dsn)
                conn.autocommit = True
                cur = conn.cursor()
                if a.sync_commit:
                    cur.execute("set synchronous_commit = " + a.sync_commit)
                cur.execute("select coalesce(current_setting('biha.id', true), '?')")
                node = cur.fetchone()[0]
                log('connect_ok', node)
            except Exception as e:
                conn = None
                log('connect_err', str(e).replace('\n', ' ').replace(',', ';')[:200])
                time.sleep(a.retry_sleep)
                continue
        seq += 1
        try:
            if a.query_timeout:
                # Запрос уходит в поток с дедлайном. По истечении соединение
                # бросается как есть и открывается новое — так делает пул с
                # таймаутом запроса. Отменять запрос через PQcancel бесполезно:
                # отмена идёт на тот же самый неотвечающий сервер.
                box = {}
                def run_q():
                    try:
                        cur.execute("insert into hb(seq, node) values (%s, current_setting('biha.id', true)) returning seq", (seq,))
                        box['r'] = cur.fetchone()[0]
                    except Exception as ex:
                        box['e'] = ex
                th = threading.Thread(target=run_q, daemon=True)
                th.start(); th.join(a.query_timeout)
                if th.is_alive():
                    raise TimeoutError(f'query timeout {a.query_timeout}s')
                if 'e' in box:
                    raise box['e']
                got = box['r']
            else:
                cur.execute("insert into hb(seq, node) values (%s, current_setting('biha.id', true)) returning seq", (seq,))
                got = cur.fetchone()[0]
            ak.write(f"{got},{time.time():.6f}\n")
            log('ok', got)
        except Exception as e:
            log('err', f"{seq};{str(e).splitlines()[0].replace(',', ';')[:160]}")
            # Соединение, брошенное по дедлайну, закрывать НЕЛЬЗЯ: его держит
            # зависший поток, и close() заблокирует уже основной поток. Просто
            # теряем ссылку — так же поступает пул, отбраковывая соединение.
            if not isinstance(e, TimeoutError):
                try:
                    conn.close()
                except Exception:
                    pass
            conn = None
            time.sleep(a.retry_sleep)

    log('run_end')
    ev.close(); ak.close()

if __name__ == '__main__':
    main()
