#!/usr/bin/env python3
"""Разбор одного прогона: фазы отказа по клиенту, по состоянию кластера и по логам.

Клиент — главная шкала: всё считается от момента внесения отказа до первой
успешной записи. Состояние кластера и лог — вторая и третья шкалы, они нужны,
чтобы увидеть расхождение между тем, что кластер говорит о себе, и тем, что
видит приложение.
"""
import csv, os, re, sys, glob
from datetime import datetime, timezone

RUN = sys.argv[1]
D = os.path.join(os.path.dirname(__file__), '..', 'data', 'runs', RUN)
name = RUN

def ts2s(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime('%H:%M:%S.%f')[:-3]

meta = {}
inj = {}
for line in open(os.path.join(D, 'meta.txt'), encoding='utf-8'):
    line = line.strip()
    if line.startswith('INJECT'):
        p = line.split()
        inj[p[3]] = float(p[4])
    elif '=' in line and not line.startswith('---'):
        k, _, v = line.partition('=')
        meta.setdefault(k, v)

T0 = inj.get('do')
UNDO = inj.get('undo')

# ---- клиентская шкала ----
events = []
with open(os.path.join(D, f'{name}.events'), encoding='utf-8') as f:
    for row in csv.reader(f):
        if len(row) >= 3:
            events.append((float(row[0]), row[2], row[3] if len(row) > 3 else ''))

ok = [e for e in events if e[1] == 'ok']
last_ok_before = max((e[0] for e in ok if e[0] < T0), default=None)
first_err = min((e[0] for e in events if e[1] in ('err', 'connect_err') and e[0] >= last_ok_before), default=None)
first_ok_after = min((e[0] for e in ok if e[0] > (first_err or T0)), default=None)
conn_after = [e for e in events if e[1] == 'connect_ok' and e[0] > (first_err or T0)]
new_node = conn_after[0][2] if conn_after else '?'
n_reconn = len([e for e in events if e[1] == 'connect_start' and first_err and e[0] >= first_err and (not first_ok_after or e[0] <= first_ok_after)])

# ошибки во время провала — по видам
errs = {}
for e in events:
    if e[1] in ('err', 'connect_err') and first_err and e[0] >= first_err and (not first_ok_after or e[0] <= first_ok_after):
        msg = e[2].split(';', 1)[-1].strip()[:70]
        errs[msg] = errs.get(msg, 0) + 1

# ---- RPO ----
acked = set()
with open(os.path.join(D, f'{name}.acked'), encoding='utf-8') as f:
    for row in csv.reader(f):
        if row:
            acked.add(int(row[0]))
stored = set()
sp = os.path.join(D, f'{name}.stored')
if os.path.exists(sp):
    stored = {int(x) for x in open(sp) if x.strip()}
lost = sorted(acked - stored)

# ---- состояние кластера ----
transitions = []
prev = {}
with open(os.path.join(D, f'{name}.state'), encoding='utf-8') as f:
    for row in csv.reader(f):
        if len(row) < 8:
            continue
        t, src, _me, nid, _lid, _term, online, state = float(row[0]), row[1], row[2], row[3], row[4], row[5], row[6], row[7]
        key = (src, nid)
        cur = f"{state}/{online}"
        if prev.get(key) != cur:
            if key in prev:
                transitions.append((t, src, nid, prev[key], cur))
            prev[key] = cur

# ---- лог ----
MARK = [
    ('broken connection', r'broken connection on socket'),
    ('demotion', r'requested Postgres restart for demotion'),
    ('ready RO', r'ready to accept read-only connections'),
    ('state switched', r'\[BiHA NC 1 \d+ (\w+)\] state switched'),
    ('promote start', r'Postgres promotion has been triggered'),
    ('promote done', r'Postgres is promoted'),
    ('ready RW', r'ready to accept connections'),
]
logev = []
for lf in sorted(glob.glob(os.path.join(D, 'pg-*.log'))):
    host = os.path.basename(lf)[3:-4]
    for line in open(lf, encoding='utf-8', errors='replace'):
        m = re.match(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) UTC ', line)
        if not m:
            continue
        t = datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S.%f').replace(tzinfo=timezone.utc).timestamp()
        if not (T0 - 5 <= t <= (first_ok_after or UNDO) + 15):
            continue
        for label, pat in MARK:
            mm = re.search(pat, line)
            if mm:
                extra = mm.group(1) if mm.groups() else ''
                logev.append((t, host, label, extra))
                break
logev.sort()

# ---- отчёт ----
print(f"# Прогон {name}: {meta.get('type')} на {meta.get('target')} ({meta.get('target_ip')})")
print(f"лидер до: {meta.get('leader_before')}   лидер после: {meta.get('leader_after')}")
print(f"отказ внесён: {ts2s(T0)}   снят: {ts2s(UNDO)}")
print()
print("## Клиент (главная шкала)")
if first_err is None:
    # Не брак: операция могла вообще не прервать запись. Это результат.
    print(f"  ошибок у клиента НЕ БЫЛО — запись не прерывалась")
    print(f"  подтверждено записей всего          : {len(acked)}")
elif last_ok_before is None or first_ok_after is None:
    print("  провал не пойман — проверь границы прогона")
else:
    print(f"  последняя успешная запись до отказа : {ts2s(last_ok_before)}  (T{last_ok_before-T0:+.3f})")
    print(f"  первая ошибка                       : {ts2s(first_err)}  (T{first_err-T0:+.3f})")
    print(f"  первая успешная запись после        : {ts2s(first_ok_after)}  (T{first_ok_after-T0:+.3f})")
    print(f"  ПРОСТОЙ ЗАПИСИ                      : {first_ok_after-last_ok_before:.2f} с")
    print(f"  новый узел приёма записи            : node {new_node}")
    print(f"  попыток переподключения             : {n_reconn}")
    print(f"  подтверждено записей всего          : {len(acked)}")
print()
print("## RPO")
print(f"  подтверждено клиенту : {len(acked)}")
print(f"  найдено в базе       : {len(stored)}")
print(f"  ПОТЕРЯНО             : {len(lost)}" + (f"  (seq {lost[0]}..{lost[-1]})" if lost else ""))
print()
print("## Состояние кластера (что кластер говорит о себе)")
for t, src, nid, a, b in transitions:
    if T0 - 3 <= t <= (first_ok_after or UNDO) + 15:
        print(f"  T{t-T0:+8.2f}  опрошен {src:15s} про node {nid}: {a} -> {b}")
print()
print("## Лог PostgreSQL")
for t, host, label, extra in logev:
    print(f"  T{t-T0:+8.2f}  {host:15s}  {label}{(' ' + extra) if extra else ''}")
print()
if errs:
    print("## Ошибки клиента во время провала")
    for m, c in sorted(errs.items(), key=lambda x: -x[1]):
        print(f"  {c:5d}  {m}")
