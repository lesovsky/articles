#!/bin/bash
# Межсерийный разброс: одни и те же замеры, чередуя базовую линию и aqo.
#
# Нужно, чтобы отделить эффект расширения от дрейфа стенда. Серии идут
# ПОПЕРЕМЕННО, а не блоками: если стенд медленно теплеет или остывает, блочный
# порядок припишет этот дрейф тому режиму, который мерили последним.
set -e
source "$(dirname "$0")/lib.sh"

ROUNDS=${ROUNDS:-3}
for r in $(seq 1 "$ROUNDS"); do
  echo "### раунд $r: базовая линия ###"
  TAG="rep-base-$r" PRESET="set aqo.enable = off;" bash "$SCRIPT_DIR/02-baseline.sh" >/dev/null 2>&1
  echo "### раунд $r: aqo frozen, раздельные классы ###"
  TAG="rep-aqo-$r" PRESET="set aqo.enable = on; set aqo.mode = 'frozen'; set aqo.advanced = on;" \
    bash "$SCRIPT_DIR/02-baseline.sh" >/dev/null 2>&1
done

echo "== Сводка: медианы по раундам =="
python3 - "$DATA_DIR" "$ROUNDS" <<'PY'
import csv, sys, os, statistics
data_dir, rounds = sys.argv[1], int(sys.argv[2])

def load(tag):
    path = os.path.join(data_dir, tag + ".csv")
    out = {}
    if not os.path.exists(path):
        return out
    for row in csv.DictReader(open(path)):
        try:
            out[row["query"]] = float(row["median_ms"])
        except (ValueError, KeyError):
            pass
    return out

base = [load(f"rep-base-{i}") for i in range(1, rounds + 1)]
aqo  = [load(f"rep-aqo-{i}")  for i in range(1, rounds + 1)]
queries = sorted({q for d in base + aqo for q in d})

print(f"{'query':9} {'base медиана':>13} {'разброс':>9} {'aqo медиана':>12} {'разброс':>9} {'дельта':>9}")
for q in queries:
    b = [d[q] for d in base if q in d]
    a = [d[q] for d in aqo if q in d]
    if not b or not a:
        continue
    bm, am = statistics.median(b), statistics.median(a)
    # разброс — размах между раундами в процентах от медианы: если он
    # сопоставим с дельтой, говорить об эффекте нельзя
    bs = (max(b) - min(b)) / bm * 100
    as_ = (max(a) - min(a)) / am * 100
    delta = (am - bm) / bm * 100
    print(f"{q:9} {bm:13.1f} {bs:8.1f}% {am:12.1f} {as_:8.1f}% {delta:+8.1f}%")
PY
