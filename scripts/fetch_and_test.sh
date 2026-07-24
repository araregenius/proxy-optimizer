#!/bin/bash
# ============================================================
# fetch_and_test.sh - Incremental two-stage proxy tester
# Strategy:
#   1. Fetch 6 sources -> pool (thousands of proxies)
#   2. Skip already-tested ones (.src/.tested, persisted via cache)
#   3. TWO-STAGE test to save time:
#        Stage 1: quick google.com probe (1 curl per proxy)
#        Stage 2: full openai+anthropic probe ONLY if Stage 1 passed
#   4. Save ALL scored results; output TOP 20 at end of run
#   5. Even if we hit 25-min timeout, whatever results we have
#      get written to verified.txt / verified.json
# ============================================================

set -uo pipefail

OUTPUT_DIR=data
SLEEP_BETWEEN=3
QUICK_TIMEOUT=4
FULL_TIMEOUT=5
RUN_LIMIT=1440

SRC_DIR=.src
mkdir -p "$OUTPUT_DIR" "$SRC_DIR"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ============================================================
# Step 1: Fetch 6 sources
# ============================================================
log 'Step 1: Fetching 6 sources...'
> "$SRC_DIR/raw.txt"
for url in \
  'https://raw.githubusercontent.com/dpangestuw/Free-Proxy/refs/heads/main/SOCKS5_proxies.txt' \
  'https://raw.githubusercontent.com/Thordata/awesome-free-proxy-list/main/proxies/socks5.txt' \
  'https://vakhov.github.io/fresh-proxy-list/socks5.txt' \
  'https://cdn.jsdelivr.net/gh/gfpcom/free-proxy-list@main/proxies/protocols/socks5/data.txt' \
  'https://cdn.jsdelivr.net/gh/proxyscrape/free-proxy-list@main/proxies/protocols/socks5/data.txt' \
  'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt'; do
  log "  -> $(basename "$url")"
  curl -sL --max-time 10 "$url" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' >> "$SRC_DIR/raw.txt" || true
done
sort -u "$SRC_DIR/raw.txt" > "$SRC_DIR/pool.txt"
total=$(wc -l < "$SRC_DIR/pool.txt")
log "  Pool: $total unique proxies"

# ============================================================
# Load state across runs (persisted via actions/cache)
# ============================================================
if [ -f "$SRC_DIR/.tested" ]; then
  sort -u "$SRC_DIR/.tested" -o "$SRC_DIR/.tested"
else
  > "$SRC_DIR/.tested"
fi
if [ -f "$OUTPUT_DIR/verified.txt" ]; then
  cp "$OUTPUT_DIR/verified.txt" "$SRC_DIR/.best.txt"
else
  > "$SRC_DIR/.best.txt"
fi
if [ ! -f "$SRC_DIR/.best_scores.txt" ]; then
  > "$SRC_DIR/.best_scores.txt"
fi

# Pick untested proxies
test -s "$SRC_DIR/.tested" \
  && grep -v -F -f "$SRC_DIR/.tested" "$SRC_DIR/pool.txt" > "$SRC_DIR/new.txt" \
  || cp "$SRC_DIR/pool.txt" "$SRC_DIR/new.txt"
new_count=$(wc -l < "$SRC_DIR/new.txt")
tested_count=$(wc -l < "$SRC_DIR/.tested" 2>/dev/null || echo 0)
log "  Already tested: $tested_count, New to test: $new_count"

# ============================================================
# Stage 1: quick google probe
#   One curl to google.com; returns latency ms or 99999
# ============================================================
quick_probe() {
  local proxy="$1"
  local s e code
  s=$(date +%s%3N)
  code=$(curl -sL -o /dev/null -w '%{http_code}' \
    -x "socks5://${proxy}" \
    --max-time "$QUICK_TIMEOUT" \
    'https://google.com' 2>/dev/null || echo 000)
  e=$(date +%s%3N)
  local lat=$(( e - s ))
  if [[ "$code" =~ ^[234] ]]; then
    echo "$lat"
  else
    echo 99999
  fi
}

# ============================================================
# Stage 2: full openai + anthropic probe
#   Only called if Stage 1 passed
#   Returns: best_latency|caps  (caps is comma-separated names)
# ============================================================
full_probe() {
  local proxy="$1"
  local caps='' best=99999
  local targets='openai:https://api.openai.com/completions|anthropic:https://api.anthropic.com/v1/messages|grok:https://api.x.ai/v1/models'
  IFS='|' read -ra arr <<< "$targets"
  for t in "${arr[@]}"; do
    local name="${t%%:*}"
    local url="${t#*:}"
    local s e code lat
    s=$(date +%s%3N)
    code=$(curl -sL -o /dev/null -w '%{http_code}' \
      -x "socks5://${proxy}" \
      --max-time "$FULL_TIMEOUT" \
      "$url" 2>/dev/null || echo 000)
    e=$(date +%s%3N)
    lat=$(( e - s ))
    if [[ "$code" =~ ^[234] ]]; then
      caps="${caps:+$caps,}$name"
      if [ "$lat" -lt "$best" ]; then best="$lat"; fi
    fi
  done
  echo "${best}|${caps}"
}

# ============================================================
# Scoring
#   score = max(0, (1000 - min_latency) / 10 + 100) + reachable_count * 20
#   reachable includes "google" (stage 1) + openai/anthropic/grok (stage 2)
# ============================================================
compute_score() {
  local best="$1" caps="$2"
  local score=0
  if [ "$best" -lt 9000 ]; then
    score=$(( (1000 - best) / 10 + 100 ))
    if [ "$score" -lt 0 ]; then score=0; fi
    local cc=0
    if [ -n "$caps" ]; then
      cc=$(echo "$caps" | tr ',' '\n' | grep -c . || true)
    fi
    score=$(( score + cc * 20 ))
  fi
  echo "$score"
}

# ============================================================
# Step 2: Test proxies
# ============================================================
log "Step 2: Testing (two-stage, sleep ${SLEEP_BETWEEN}s between each)..."
run_start=$(date +%s)
scanned=0
passed=0
while IFS= read -r proxy; do
  [ -z "$proxy" ] && continue
  scanned=$(( scanned + 1 ))
  now=$(date +%s)
  elapsed=$(( now - run_start ))
  if [ "$elapsed" -gt "$RUN_LIMIT" ]; then
    log "  STOP: reached ${RUN_LIMIT}s limit, tested $scanned proxies this run"
    break
  fi

  # --- Stage 1: quick google probe ---
  lat=$(quick_probe "$proxy")
  echo "$proxy" >> "$SRC_DIR/.tested"
  sleep "$SLEEP_BETWEEN"

  if [ "$lat" -ge 9000 ]; then
    log "  [$scanned] [$proxy] DEAD (google not reachable)"
    continue
  fi

  passed=$(( passed + 1 ))
  caps='google'
  best=$lat
  log "  [$scanned] [$proxy] STAGE1 OK lat=${lat}ms -> stage 2..."

  # --- Stage 2: full probe ---
  result=$(full_probe "$proxy")
  s2_best=$(echo "$result" | cut -d'|' -f1)
  s2_caps=$(echo "$result" | cut -d'|' -f2)
  if [ -n "$s2_caps" ]; then
    caps="${caps},${s2_caps}"
  fi
  if [ "$s2_best" -lt "$best" ]; then best=$s2_best; fi

  score=$(compute_score "$best" "$caps")
  ip=$(echo "$proxy" | cut -d: -f1)
  port=$(echo "$proxy" | cut -d: -f2)
  log "  [$scanned] [$proxy] score=$score latency=${best}ms caps=[${caps}]"
  echo "${score}|${ip}|${port}|${best}|${caps}" >> "$SRC_DIR/.best_scores.txt"
  sleep "$SLEEP_BETWEEN"
done < "$SRC_DIR/new.txt"

log "Scan complete: scanned=$scanned, passed=$passed"

# ============================================================
# Step 3: Select TOP 20 from ALL scores (old + new)
# ============================================================
log 'Step 3: Selecting TOP 20...'
sort -t'|' -k1 -rn "$SRC_DIR/.best_scores.txt" \
  | awk -F'|' '$1 > 0' | head -20 > "$SRC_DIR/top20.txt"
pass_count=$(wc -l < "$SRC_DIR/top20.txt")
log "  TOP 20: $pass_count proxies"

# --- Write verified.txt ---
TXT_FILE="$OUTPUT_DIR/verified.txt"
> "$TXT_FILE"
while IFS='|' read -r score ip port lat caps; do
  [ -z "$score" ] && continue
  echo "socks5://${ip}:${port}  # score:${score} latency:${lat}ms caps:[${caps}]" >> "$TXT_FILE"
done < "$SRC_DIR/top20.txt"

# --- Write verified.json ---
JSON_FILE="$OUTPUT_DIR/verified.json"
{
  echo '{'
  echo '  "updated_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)",'
  echo '  "total_pool": '$total','
  echo '  "tested_this_run": '$scanned','
  echo '  "total_tested": '$(wc -l < "$SRC_DIR/.tested")','
  echo '  "top_proxies": ['
} > "$JSON_FILE"

first=true
while IFS='|' read -r score ip port lat caps; do
  [ -z "$score" ] && continue
  if [ "$first" = "false" ]; then echo ',' >> "$JSON_FILE"; fi
  first=false
  cj=''
  IFS=',' read -ra arr <<< "$caps"
  for c in "${arr[@]}"; do
    [ -n "$c" ] || continue
    [ -n "$cj" ] && cj="$cj, "
    cj="${cj}\"${c}\""
  done
  echo "    {" >> "$JSON_FILE"
  echo "      \"ip\": \"${ip}\"," >> "$JSON_FILE"
  echo "      \"port\": ${port}," >> "$JSON_FILE"
  echo "      \"capabilities\": [${cj}]," >> "$JSON_FILE"
  echo "      \"latency_min\": ${lat}," >> "$JSON_FILE"
  echo "      \"score\": ${score}" >> "$JSON_FILE"
  echo "    }" >> "$JSON_FILE"
done < "$SRC_DIR/top20.txt"
echo '  ]' >> "$JSON_FILE"
echo '}' >> "$JSON_FILE"

# --- Write data/README.md ---
cat > "$OUTPUT_DIR/README.md" << EOF
# Verified SOCKS5 Proxies
> Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## Stats
- Pool size: ${total}
- Tested this run: ${scanned}
- Total tested (all runs): $(wc -l < "$SRC_DIR/.tested")
- In TOP 20: ${pass_count}

## Subscribe
TXT: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt
JSON: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.json

## Score
Base: (1000 - min_latency) / 10 + 100
Each reachable target +20 (google/openai/anthropic/grok)

## Strategy
- Two-stage test: quick google probe first, then openai+anthropic for passers only
- Tested history persists across runs via GitHub Actions cache (.src/.tested)
- Outputs whatever we have at end of 25-min run
EOF

log 'Done!'
ls -la "$OUTPUT_DIR/"
