#!/usr/bin/env python3
"""Обрезка логов прогонов до окна вокруг отказа.

runexp.sh копировал с каждого узла весь дневной файл лога — то есть одно и то
же содержимое повторялось в каждом прогоне. Для анализа нужно окно вокруг
момента отказа; остальное — дубликаты, раздувавшие каталог до 600 MB.
"""
import glob, os, re, sys
from datetime import datetime, timezone

BEFORE, AFTER = 120, 240   # секунд до и после инжекции

total_before = total_after = 0
for d in sorted(glob.glob('data/runs/*/')):
    meta_p = os.path.join(d, 'meta.txt')
    if not os.path.exists(meta_p):
        continue
    m = re.search(r'INJECT \S+ \S+ do (\S+)', open(meta_p, encoding='utf-8').read())
    if not m:
        continue
    T0 = float(m.group(1))
    lo, hi = T0 - BEFORE, T0 + AFTER
    for lf in glob.glob(os.path.join(d, 'pg-*.log')):
        total_before += os.path.getsize(lf)
        keep, inside = [], False
        for line in open(lf, encoding='utf-8', errors='replace'):
            ts = re.match(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) UTC ', line)
            if ts:
                t = datetime.strptime(ts.group(1), '%Y-%m-%d %H:%M:%S.%f').replace(tzinfo=timezone.utc).timestamp()
                inside = lo <= t <= hi
            if inside:      # строки продолжения без метки идут за своей записью
                keep.append(line)
        with open(lf, 'w', encoding='utf-8') as f:
            f.writelines(keep)
        total_after += os.path.getsize(lf)

print(f"логи: {total_before/1048576:.0f} MB -> {total_after/1048576:.1f} MB")
