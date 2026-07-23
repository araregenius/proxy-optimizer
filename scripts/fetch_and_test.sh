#!/bin/bash
set -euo pipefail

OUTPUT_DIR='data'
PROXY_TIMEOUT=8
MAX_TEST=300
CONCURRENCY=20

SOURCES=(
  'https://raw.githubusercontent.com/dpangestuw/Free-Proxy/refs/heads/main/SOCKS5_proxies.txt'
  'https://raw.githubusercontent.com/Thordata/awesome-free-proxy-list/main/proxies/socks5.txt'
  'https://vakhov.github.io/fresh-proxy-list/socks5.txt'
  'https://cdn.jsdelivr.net/gh/gfpcom/free-proxy-list@main/proxies/protocols/socks5/data.txt'
  'https://cdn.jsdelivr.net/gh/proxyscrape/free-proxy-list@main/proxies/protocols/socks5/data.txt'
  'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt'
)

TARGETS=(
  'openai:https://api.openai.com/completions'
  'anthropic:https://api.anthropic.com/v1/messages'
  'google:https://google.com'
)

mkdir -p "$OUTPUT_DIR"
TMPDIR=$(mktemp -d)
trap 'rm -rf $TMPDIR' EXIT

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

log 'Step 1/5: Fetching...'
ALL_FILE="$TMPDIR/all.txt"
> "$ALL_FILE"
for url in "${SOURCES[@]}"; do
  log "  -> $url"
  curl -sL --max-time 15 "$url" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' >> "$ALL_FILE" || true
done
total_raw=$(sort -u "$ALL_FILE" | wc -l)
log "  Fetched: $total_raw unique"

log 'Step 2/5: Sampling...'
sort -u "$ALL_FILE" > "$TMPDIR/unique.txt"
if [ "$total_raw" -gt "$MAX_TEST" ]; then
  shuf "$TMPDIR/unique.txt" | head -n "$MAX_TEST" > "$TMPDIR/sample.txt"
else
  cp "$TMPDIR/unique.txt" "$TMPDIR/sample.txt"
fi
sample_count=$(wc -l < "$TMPDIR/sample.txt")
log "  Sampled: $sample_count"

test_proxy() {
  local proxy="$1"
  local ip port
  ip=$(echo "$proxy" | cut -d: -f1)
  port=$(echo "$proxy" | cut -d: -f2)
  local caps=''
  local best_latency=99999
  for t in "${TARGETS[@]}"; do
    local name=${t%%:*}
    local url=${t#*:}
    local start_ms end_ms latency http_code
    start_ms=$(date +%s%3N)
    http_code=$(curl -sL -o /dev/null -w '%{http_code}' -x "socks5://${proxy}" --max-time "$PROXY_TIMEOUT" "$url" 2>/dev/null || echo '000')
    end_ms=$(date +%s%3N)
    latency=$((end_ms - start_ms))
    if [[ "$http_code" =~ ^[234] ]]; then
      caps="$caps,$name"
      if [ "$latency" -lt "$best_latency" ]; then best_latency=$latency; fi
    fi
  done
  caps=${caps#,}
  local score=0
  if [ "$best_latency" -lt 9000 ]; then
    score=$(( (1000 - best_latency) / 10 + 100 ))
    [ $score -lt 0 ] && score=0
    local cap_count=$(echo "$caps" | tr ',' '\n' | wc -l)
    score=$(( score + cap_count * 20 ))
  fi
  echo "${score}|${ip}|${port}|${best_latency}|${caps}"
}

export -f test_proxy

log 'Step 3/5: Testing...'
RESULTS_FILE="$TMPDIR/results.txt"
> "$RESULTS_FILE"
cat "$TMPDIR/sample.txt" | xargs -P "$CONCURRENCY" -I{} bash -c 'test_proxy "{}"' >> "$RESULTS_FILE" 2>/dev/null || true
log '  Done testing'

log 'Step 4/5: Generating output...'
sort -t'|' -k1 -rn "$RESULTS_FILE" | awk -F'|' '$1 > 0' > "$TMPDIR/passed.txt" 2>/dev/null || true
PASS_COUNT=$(wc -l < "$TMPDIR/passed.txt")
log "  Passed: $PASS_COUNT / $sample_count"

TXT_FILE="$OUTPUT_DIR/verified.txt"
> "$TXT_FILE"
while IFS='|' read -r score ip port latency caps; do
  [ -z "$score" ] && continue
  echo "socks5://${ip}:${port}  # score:${score} latency:${latency}ms caps:${caps}" >> "$TXT_FILE"
done < "$TMPDIR/passed.txt"

JSON_FILE="$OUTPUT_DIR/verified.json"
{
  echo '{'
  echo '  "updated_at": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",'
  echo '  "total_fetched": '$(total_raw)','
  echo '  "tested": '$(sample_count)','
  echo '  "passed": '$(PASS_COUNT)','
  echo '  "proxies": ['
} > "$JSON_FILE"

first=true
while IFS='|' read -r score ip port latency caps; do
  [ -z "$score" ] && continue
  $first || echo ',' >> "$JSON_FILE"
  first=false
  cap_json=''
  IFS=',' read -ra cap_arr <<< "$caps"
  for c in "${cap_arr[@]}"; do
    [ -n "$c" ] || continue
    [ -n "$cap_json" ] && cap_json="${cap_json}, "
    cap_json="${cap_json}\"${c}\""
  done
  echo '    {' >> "$JSON_FILE"
  echo '      "ip": "${ip}",' >> "$JSON_FILE"
  echo '      "port": ${port},' >> "$JSON_FILE"
  echo '      "capabilities": [${cap_json}],' >> "$JSON_FILE"
  echo '      "latency_min": ${latency},' >> "$JSON_FILE"
  echo '      "score": ${score}' >> "$JSON_FILE"
  echo '    }' >> "$JSON_FILE"
done < "$TMPDIR/passed.txt"

echo '  ]' >> "$JSON_FILE"
echo '}' >> "$JSON_FILE"

GEN_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo '# Verified SOCKS5 Proxies'
  echo '> Updated: ${GEN_TIME}'
  echo ''
  echo '## Stats'
  echo "- Total fetched: ${total_raw}"
  echo "- Tested: ${sample_count}"
  echo "- Passed: ${PASS_COUNT}"
  echo ''
  echo '## Subscribe'
  echo 'TXT: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt'
  echo 'JSON: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.json'
  echo ''
  echo '## Score'
  echo 'Base: (1000 - min_latency) / 10 + 100'
  echo 'Each reachable target +20 (openai/anthropic/google)'
} > "$OUTPUT_DIR/README.md"

log 'Done!'
ls -la "$OUTPUT_DIR/"
