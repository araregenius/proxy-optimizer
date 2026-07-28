# Verified SOCKS5 Proxies
> Updated: 2026-07-28T19:11:23Z

## Stats
- Pool size: 1845
- Tested this run: 822
- Total tested all runs: 6553
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
- Reachability = TCP+TLS handshake success (not 2xx)
- State persisted in data/.tested and data/.best_scores.txt (committed to repo)
