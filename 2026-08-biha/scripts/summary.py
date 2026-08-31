#!/usr/bin/env python3
"""Сводная таблица по всем прогонам: строка на прогон, агрегат на тип отказа.

Считает то, что идёт в таблицу поста: простой записи по клиенту и фазы, из
которых он складывается. Фазы берутся из логов узлов (детект и promote) и из
опроса состояния (когда кластер объявил узел потерянным).
"""
import csv, os, re, sys, glob, statistics
from datetime import datetime, timezone

BASE = os.path.join(os.path.dirname(__file__), '..', 'data', 'runs')

def load(run):
    D = os.path.join(BASE, run)
    meta, inj = {}, {}
    for line in open(os.path.join(D, 'meta.txt'), encoding='utf-8'):
        line = line.strip()
        if line.startswith('INJECT'):
            p = line.split(); inj[p[3]] = float(p[4])
        elif '=' in line and not line.startswith('---'):
            k, _, v = line.partition('='); meta.setdefault(k, v)
    T0 = inj.get('do')
    # прогон может быть ещё в работе — тогда файлов нет, просто пропускаем
    if T0 is None or not os.path.exists(os.path.join(D, f'{run}.events')):
        return None
    ev = []
    with open(os.path.join(D, f'{run}.events'), encoding='utf-8') as f:
        for row in csv.reader(f):
            if len(row) >= 3:
                ev.append((float(row[0]), row[2]))
    ok = [t for t, k in ev if k == 'ok']
    last_ok = max((t for t in ok if t < T0), default=None)
    first_err = min((t for t, k in ev if k in ('err', 'connect_err') and t >= (last_ok or T0)), default=None)
    first_ok = min((t for t in ok if first_err and t > first_err), default=None)

    # Прогон, где клиент так и не восстановился, — не брак, а результат:
    # молча выбрасывать его нельзя, иначе из таблицы исчезают худшие случаи.
    # Прогон вообще без ошибок — тоже результат: операция не прервала запись.
    if first_err is None:
        return dict(run=run, type=meta.get('type'), conn=meta.get('conn_extra', '') or 'по умолчанию',
                    T0=T0, stuck=False, nogap=True, down=0.0, to_err=None, to_lost=None,
                    to_cand=None, to_promote=None, to_ok=None, acked=0, lost_rows=0)
    stuck = first_ok is None
    end = first_ok if first_ok else max(t for t, _ in ev)

    acked = sum(1 for _ in open(os.path.join(D, f'{run}.acked'), encoding='utf-8'))
    sp = os.path.join(D, f'{run}.stored')
    stored = sum(1 for x in open(sp) if x.strip()) if os.path.exists(sp) else None
    # точный RPO
    lost = None
    if stored is not None:
        a = {int(r[0]) for r in csv.reader(open(os.path.join(D, f'{run}.acked'), encoding='utf-8')) if r}
        s = {int(x) for x in open(sp) if x.strip()}
        lost = len(a - s)

    # когда кластер объявил узел потерянным
    lost_at = None
    prev = {}
    with open(os.path.join(D, f'{run}.state'), encoding='utf-8') as f:
        for row in csv.reader(f):
            if len(row) < 8:
                continue
            t, src, nid, online = float(row[0]), row[1], row[3], row[6]
            key = (src, nid)
            if prev.get(key) == 'True' and online == 'False' and t >= T0 and lost_at is None:
                lost_at = t
            prev[key] = online

    # фазы из логов
    marks = {}
    for lf in glob.glob(os.path.join(D, 'pg-*.log')):
        for line in open(lf, encoding='utf-8', errors='replace'):
            m = re.match(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) UTC ', line)
            if not m:
                continue
            t = datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S.%f').replace(tzinfo=timezone.utc).timestamp()
            if not (T0 <= t <= end + 5):
                continue
            for lbl, pat in (('cand', r'\] state switched'), ('promote', r'Postgres promotion has been triggered'), ('rw', r'state switched$')):
                pass
            if 'CANDIDATE] state switched' in line and 'cand' not in marks:
                marks['cand'] = t
            if 'Postgres promotion has been triggered' in line and 'promote' not in marks:
                marks['promote'] = t
    return dict(run=run, type=meta.get('type'), conn=meta.get('conn_extra', '') or 'по умолчанию', T0=T0, stuck=stuck,
                down=end - last_ok,
                to_err=first_err - T0,
                to_lost=(lost_at - T0) if lost_at else None,
                to_cand=(marks.get('cand', 0) - T0) if 'cand' in marks else None,
                to_promote=(marks.get('promote', 0) - T0) if 'promote' in marks else None,
                to_ok=end - T0, acked=acked, lost_rows=lost)

runs = sorted(os.path.basename(d) for d in glob.glob(os.path.join(BASE, '*')) if os.path.isdir(d))
rows = [r for r in (load(x) for x in runs) if r]

def f(v, w=6):
    return f"{v:{w}.2f}" if isinstance(v, float) else ('  —  ' if v is None else str(v))

print("  ! — клиент НЕ восстановился до конца прогона: цифра ограничена длительностью опыта, а не системой")
print(f"{'прогон':22s} {'простой':>8s} {'ошибка':>7s} {'потерян':>8s} {'выборы':>7s} {'promote':>8s} {'запись':>7s} {'RPO':>5s}")
print('-' * 82)
for r in rows:
    if r.get('nogap'):
        print(f"{r['run']:20s}    запись не прерывалась")
        continue
    mark = ' !' if r['stuck'] else '  '
    print(f"{r['run']:20s}{mark} {f(r['down'],8)} {f(r['to_err'],7)} {f(r['to_lost'],8)} {f(r['to_cand'],7)} {f(r['to_promote'],8)} {f(r['to_ok'],7)} {f(r['lost_rows'],5)}")

print()
print("## Агрегат по сериям (медиана простоя записи, с)")
by = {}
for r in rows:
    if r.get('nogap'):
        continue
    series = re.sub(r'-r\d+$', '', r['run'])
    by.setdefault(series, []).append(r)
print(f"{'серия':22s} {'n':>3s} {'медиана':>9s} {'мин':>7s} {'макс':>7s} {'разброс':>8s} {'RPO':>6s}")
print('-' * 70)
for series, rs in sorted(by.items()):
    d = [x['down'] for x in rs]
    rp = sum(x['lost_rows'] or 0 for x in rs)
    spread = (max(d) - min(d)) / statistics.median(d) * 100 if len(d) > 1 else 0
    nstuck = sum(1 for x in rs if x['stuck'])
    note = f"  из них не восстановились: {nstuck}" if nstuck else ""
    print(f"{series:22s} {len(d):3d} {statistics.median(d):9.2f} {min(d):7.2f} {max(d):7.2f} {spread:7.1f}% {rp:6d}{note}")
