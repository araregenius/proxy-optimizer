# Verified SOCKS5 Proxies
> Updated: 2026-08-25T19:52:23Z

## Stats
- Pool size: 545
- Tested this run: 0
- Total tested all runs: 12562
- In TOP 20: 20

## Subscribe
TXT: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt
JSON: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.json

## Score
Base: (1000 - min_latency) / 10 + 100
Each reachable target +20 (google/openai/anthropic/grok — all equal weight)

## Strategy
- Parallel fetch from 6 sources
- Previous TOP 20 retested first every run
- Concurrent probe of all 4 targets per proxy
- Success requires a usable HTTP response; 403/407/5xx are rejected
- State persisted in data/.tested and data/.best_scores.txt (committed to repo)
