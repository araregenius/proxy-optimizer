#!/bin/bash
# ============================================================
# fetch_and_test.sh — Incremental proxy tester
# Strategy:
#   1. Fetch 6 sources → pool (thousands of proxies)
#   2. Skip already-tested ones (tracked in .src/.tested)
#   3. Test ONE at a time with a sleep interval (don't hammer)
#   4. Each run: ~20 min → ~400 proxies tested at 3s interval
#   5. Merge with existing best → keep TOP 20 only
# ============================================================

set -euo pipefail

OUTPUT_DIR=data
SLEEP_BETWEEN=3
TEST_TIMEOUT=5

SRC_DIR=.src
mkdir -p $OUTPUT_DIR $SRC_DIR

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log 'Step 1: Fetching 6 sources...'
> $SRC_DIR/raw.txt
for url in \
  'https://raw.githubusercontent.com/dpangestuw/Free-Proxy/refs/heads/main/SOCKS5_proxies.txt' \
  'https://raw.githubusercontent.com/Thordata/awesome-free-proxy-list/main/proxies/socks5.txt' \
  'https://vakhov.github.io/fresh-proxy-list/socks5.txt' \
  'https://cdn.jsdelivr.net/gh/gfpcom/free-proxy-list@main/proxies/protocols/socks5/data.txt' \
  'https://cdn.jsdelivr.net/gh/proxyscrape/free-proxy-list@main/proxies/protocols/socks5/data.txt' \
  'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt'; do
  log "  -> $(basename $url)"
  curl -sL --max-time 10 "$url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' >> $SRC_DIR/raw.txt || true
done
sort -u $SRC_DIR/raw.txt > $SRC_DIR/pool.txt
total=$(wc -l < $SRC_DIR/pool.txt)
log "  Pool: $total unique proxies"

# Load existing state across runs
> $SRC_DIR/.tested 2>/dev/null || true
if [ -f $SRC_DIR/.tested ]; then
  sort -u $SRC_DIR/.tested -o $SRC_DIR/.tested
fi
if [ -f $OUTPUT_DIR/verified.txt ]; then
  cp $OUTPUT_DIR/verified.txt $SRC_DIR/.best.txt
else
  > $SRC_DIR/.best.txt
fi

# Pick untested proxies
test -s $SRC_DIR/.tested && grep -v -F -f $SRC_DIR/.tested $SRC_DIR/pool.txt > $SRC_DIR/new.txt || cp $SRC_DIR/pool.txt $SRC_DIR/new.txt
new_count=$(wc -l < $SRC_DIR/new.txt)
tested_count=$(wc -l < $SRC_DIR/.tested 2>/dev/null || echo 0)
log "  Already tested: $tested_count, New to test: $new_count"

test_one() {
  local proxy="$1"
  local ip port
  ip=$(echo "$proxy" | cut -d: -f1)
  port=$(echo "$proxy" | cut -d: -f2)
  local caps='' best=99999

  for t in 'openai:https://api.openai.com/completions' 'anthropic:https://api.anthropic.com/v1/messages' 'google:https://google.com'; do
    local name=${t%%:*}
    local url=${t#*:}
    local s e code lat
    s=$(date +%s%3N)
    code=$(curl -sL -o /dev/null -w '%{http_code}' -x "socks5://${proxy}" --max-time $TEST_TIMEOUT "$url" 2>/dev/null || echo 000)
    e=$(date +%s%3N)
    lat=$(( e - s ))
    if [[ "$code" =~ ^[234] ]]; then
      caps="$caps,$name"
      if [ $lat -lt $best ]; then best=$lat; fi
    fi
  done

  caps=${caps#,}
  local score=0
  if [ $best -lt 9000 ]; then
    score=$(( (1000 - best) / 10 + 100 ))
    [ $score -lt 0 ] && score=0
    local cc=$(echo "$caps" | tr ',' '\n' | grep -c . || true)
    score=$(( score + cc * 20 ))
  fi

  echo "${score}|${ip}|${port}|${best}|${caps}"
}

log 'Step 2: Testing proxies one-by-one (sleep ${SLEEP_BETWEEN}s between each)...'
run_start=$(date +%s)

while IFS= read -r proxy; do
  [ -z "$proxy" ] && continue

  now=$(date +%s)
  elapsed=$(( now - run_start ))
  if [ $elapsed -gt 1440 ]; then
    log '  Stopping: approaching timeout (24 min)'
    break
  fi

  result=$(test_one "$proxy")
  score=$(echo "$result" | cut -d'|' -f1)
  lat=$(echo "$result" | cut -d'|' -f4)
  caps=$(echo "$result" | cut -d'|' -f5)

  log "  [$proxy] score=$score latency=${lat}ms caps=[$caps]"

  # Mark as tested (persist across runs)
  echo "$proxy" >> $SRC_DIR/.tested

  # If score > 0, add to best list
  if [ $score -gt 0 ]; then
    echo "$result" >> $SRC_DIR/.best.txt
  fi

  sleep $SLEEP_BETWEEN
done < $SRC_DIR/new.txt

log 'Step 3: Selecting TOP 20...'
# Merge: all scored results (new + old), sort by score, keep top 20
sort -t'|' -k1 -rn $SRC_DIR/.best.txt | awk -F'|' '$1 > 0' | head -20 > $SRC_DIR/top20.txt
pass_count=$(wc -l < $SRC_DIR/top20.txt)
log "  TOP 20: $pass_count proxies"

# Write verified.txt
TXT_FILE=$OUTPUT_DIR/verified.txt
> $TXT_FILE
while IFS='|' read -r score ip port lat caps; do
  [ -z "$score" ] && continue
  echo "socks5://${ip}:${port}  # score:${score} latency:${lat}ms caps:[${caps}]" >> $TXT_FILE
done < $SRC_DIR/top20.txt

# Write verified.json
JSON_FILE=$OUTPUT_DIR/verified.json
{
  echo '{'
  echo '  "updated_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",'
  echo '  "total_pool": '$total','
  echo '  "tested_this_run": '$new_count','
  echo '  "total_tested": '$(wc -l < $SRC_DIR/.tested)','
  echo '  "top_proxies": ['
} > $JSON_FILE

first=true
while IFS='|' read -r score ip port lat caps; do
  [ -z "$score" ] && continue
  $first || echo ',' >> $JSON_FILE
  first=false
  cj=''
  IFS=',' read -ra arr <<< "$caps"
  for c in "${arr[@]}"; do
    [ -n "$c" ] || continue
    [ -n "$cj" ] && cj="$cj, "
    cj="$cj\"${c}\""
  done
  echo '    {' >> $JSON_FILE
  echo '      "ip": "${ip}",' >> $JSON_FILE
  echo '      "port": ${port},' >> $JSON_FILE
  echo '      "capabilities": [${cj}],' >> $JSON_FILE
  echo '      "latency_min": ${lat},' >> $JSON_FILE
  echo '      "score": ${score}' >> $JSON_FILE
  echo '    }' >> $JSON_FILE
done < $SRC_DIR/top20.txt

echo '  ]' >> $JSON_FILE
echo '}' >> $JSON_FILE

# Write data/README.md
cat > $OUTPUT_DIR/README.md << EOF
# Verified SOCKS5 Proxies
> Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Stats
- Pool size: ${total}
- Tested this run: ${new_count}
- Total tested (all runs): $(wc -l < $SRC_DIR/.tested)
- In TOP 20: ${pass_count}

## Subscribe
TXT: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt
JSON: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.json

## Score
Base: (1000 - min_latency) / 10 + 100
Each reachable target +20 (openai/anthropic/google)

## Strategy
- Each run tests NEW proxies one-by-one with 3s interval
- Tested history persists across runs (.src/.tested)
- Only TOP 20 kept in verified.txt
EOF

log 'Done!'
ls -la $OUTPUT_DIR/
