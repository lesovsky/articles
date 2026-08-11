#!/usr/bin/env bash
# Roll the raw sampler output up into two post-ready tables:
#   summary.csv - median/min/max elapsed per cell
#   waits.csv   - share of samples per (tag, backend_type, wait_event)
set -euo pipefail
R=${RESULTS:-/bench/results}

# elapsed: median over iterations, taking the slowest session of each iteration
# (that is what the user waits for when sessions run concurrently)
awk -F, 'NR>1 {
    key = $1 "," $2 "," $3 "," $4 "," $5 "," $6 "," $7 "," $8 "," $9
    it  = key "," $10
    if ($12 > mx[it]) mx[it] = $12
    seen[it] = key
  }
  END {
    for (i in seen) { k = seen[i]; n[k]++; v[k, n[k]] = mx[i] }
    print "exp,tag,workload,io_method,io_min_workers,io_max_workers,eic,combine_limit,concurrency,n,min_ms,median_ms,max_ms"
    for (k in n) {
      c = n[k]; for (a = 1; a <= c; a++) for (b = a + 1; b <= c; b++)
        if (v[k, b] < v[k, a]) { t = v[k, a]; v[k, a] = v[k, b]; v[k, b] = t }
      med = (c % 2) ? v[k, (c + 1) / 2] : (v[k, c / 2] + v[k, c / 2 + 1]) / 2
      print k "," c "," v[k, 1] "," med "," v[k, c]
    }
  }' "$R/results.csv" | (read -r h; echo "$h"; sort -t, -k2,2) > "$R/summary.csv"

# wait events: only samples of processes doing something, grouped per run tag
{
  echo "tag,backend_type,wait_event_type,wait_event,samples,pct"
  for f in "$R"/waits/*.csv; do
    [ -e "$f" ] || continue
    tag=$(basename "$f" .csv); tag=${tag%_i*}
    awk -F, -v tag="$tag" '
      $3 != "" { total++; c[$3 "," $5 "," $6]++ }
      END { for (k in c) printf "%s,%s,%d,%.1f\n", tag, k, c[k], 100 * c[k] / total }' "$f"
  done
} | sort -t, -k1,1 -k5,5rn > "$R/waits.csv"

echo "--- summary.csv ---"; column -s, -t "$R/summary.csv" | head -60
echo; echo "--- top waits ---"; column -s, -t "$R/waits.csv" | head -40
