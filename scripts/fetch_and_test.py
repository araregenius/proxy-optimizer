#!/usr/bin/env python3
"""fetch_and_test.py — Concurrent proxy tester with persistent state in data/.

Key behaviours:
- 6 sources fetched in parallel (ThreadPoolExecutor)
- Previous TOP 20 retested FIRST every run — dead ones evicted, live ones re-scored
- All 4 targets (google/openai/anthropic/grok) tested concurrently per proxy
- Target success requires a valid HTTP response; proxy-auth failures, 5xx, and blocked responses are rejected
- SOCKS5 remote DNS is used so local DNS does not affect the result
- All 4 targets weighted equally: +20 each
- .tested / .best_scores.txt stored in data/ and committed to repo
- Batch writes: data files flushed after every batch, not every single proxy

Requires: pip install PySocks
"""

import os, re, sys, json, time, signal, atexit, ssl, threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from urllib import request as urllib_request

try:
    import socks
except ImportError:
    print("PySocks not installed. Install with: pip install PySocks", file=sys.stderr)
    sys.exit(1)

OUTPUT_DIR   = "data"
BATCH        = 30
TIMEOUT      = 8
RUN_LIMIT    = 1440
MAX_RESPONSE_BYTES = 4096
BATCH_GAP    = 0.5

TESTED_FILE       = f"{OUTPUT_DIR}/.tested"
BEST_SCORES_FILE  = f"{OUTPUT_DIR}/.best_scores.txt"
VERIFIED_TXT      = f"{OUTPUT_DIR}/verified.txt"
VERIFIED_JSON     = f"{OUTPUT_DIR}/verified.json"
README_MD         = f"{OUTPUT_DIR}/README.md"

SOURCES = [
    "https://raw.githubusercontent.com/dpangestuw/Free-Proxy/refs/heads/main/SOCKS5_proxies.txt",
    "https://raw.githubusercontent.com/Thordata/awesome-free-proxy-list/main/proxies/socks5.txt",
    "https://vakhov.github.io/fresh-proxy-list/socks5.txt",
    "https://cdn.jsdelivr.net/gh/gfpcom/free-proxy-list@main/proxies/protocols/socks5/data.txt",
    "https://cdn.jsdelivr.net/gh/proxyscrape/free-proxy-list@main/proxies/protocols/socks5/data.txt",
    "https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt",
]

ALL_TARGETS = [
    ("google",    "https://google.com"),
    ("openai",    "https://api.openai.com/completions"),
    ("anthropic", "https://api.anthropic.com/v1/messages"),
    ("grok",      "https://api.x.ai/v1/models"),
]

IP_PORT_RE = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}:\d{1,5}(?!\d)")


def valid_proxy(value):
    try:
        host, port_s = value.rsplit(":", 1)
        octets = host.split(".")
        port = int(port_s)
        return len(octets) == 4 and all(0 <= int(o) <= 255 for o in octets) and 1 <= port <= 65535
    except (ValueError, TypeError):
        return False


def target_response_is_usable(name, code):
    if code == 407 or code == 0 or code >= 500 or code == 403:
        return False
    if name == "google":
        return 200 <= code < 400
    return code in {200, 201, 204, 400, 401, 404, 405, 422}

_total   = 0
_scanned = 0
_passed  = 0
_write_lock   = threading.Lock()
_tested_lock  = threading.Lock()
_tested_buf = []
_scores_buf = []
_all_scores = {}

def log(msg):
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)

def http_get(url, timeout=10):
    try:
        req = urllib_request.Request(url, headers={"User-Agent": "proxy-optimizer/1.0"})
        with urllib_request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", errors="ignore")
    except Exception:
        return 0, ""

def _host_of(url):
    return url.split("/")[2]

def _path_of(url):
    parts = url.split("/", 3)
    return "/" + parts[3] if len(parts) > 3 else "/"

def socks_probe(host, port, url, timeout):
    try:
        s = socks.socksocket()
        # Let the SOCKS5 server resolve target hostnames.
        s.set_proxy(socks.SOCKS5, host, port, rdns=True)
        s.settimeout(timeout)
        start = time.time()
        s.connect((_host_of(url), 443))
        ctx = ssl.create_default_context()
        ss = ctx.wrap_socket(s, server_hostname=_host_of(url))
        req = (
            f"GET {_path_of(url)} HTTP/1.1\r\n"
            f"Host: {_host_of(url)}\r\n"
            "User-Agent: proxy-optimizer/1.0\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        ss.sendall(req)
        resp = ss.recv(MAX_RESPONSE_BYTES)
        lat = int((time.time() - start) * 1000)
        ss.close()
        parts = resp.split(b" ", 2)
        code = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        return (code, lat)
    except Exception:
        return (0, 99999)

def probe_one_target(args):
    proxy, name, url = args
    host, port = proxy.split(":")
    code, lat = socks_probe(host, int(port), url, TIMEOUT)
    return (name, code, lat)

def probe_all_targets(proxy):
    tasks = [(proxy, name, url) for name, url in ALL_TARGETS]
    caps = []
    best = 99999
    with ThreadPoolExecutor(max_workers=len(ALL_TARGETS)) as ex:
        futures = {ex.submit(probe_one_target, t): t[1] for t in tasks}
        for fut in as_completed(futures):
            try:
                name, code, lat = fut.result()
                if target_response_is_usable(name, code):
                    caps.append(name)
                    if lat < best:
                        best = lat
            except Exception:
                pass
    return caps, best

def compute_score(best_lat, caps):
    if best_lat >= 9000:
        return 0
    base = max(0, (1000 - best_lat) // 10 + 100)
    return base + len(caps) * 20

def fetch_all():
    log("Step 1: Fetching 6 sources (parallel) ...")
    pool = set()
    def fetch_one(url):
        name = url.rstrip("/").rsplit("/", 1)[-1]
        code, body = http_get(url, 10)
        found = {proxy for proxy in IP_PORT_RE.findall(body) if valid_proxy(proxy)}
        return name, found
    with ThreadPoolExecutor(max_workers=len(SOURCES)) as ex:
        futures = {ex.submit(fetch_one, u): u for u in SOURCES}
        for fut in as_completed(futures):
            try:
                name, s = fut.result()
                log(f"  -> {name}: {len(s)} proxies")
                pool.update(s)
            except Exception:
                log(f"  -> {futures[fut]}: FAILED")
    log(f"  Pool: {len(pool)} unique")
    return pool

def load_state():
    global _all_scores
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    tested = set()
    if os.path.isfile(TESTED_FILE):
        with open(TESTED_FILE) as f:
            tested = {line.strip() for line in f if line.strip()}
    if os.path.isfile(BEST_SCORES_FILE):
        with open(BEST_SCORES_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "|" in line:
                    parts = line.split("|", 4)
                    if len(parts) >= 5:
                        _all_scores[f"{parts[1]}:{parts[2]}"] = line
    prev_top20 = []
    if os.path.isfile(VERIFIED_JSON):
        try:
            with open(VERIFIED_JSON) as f:
                prev = json.load(f)
            for p in prev.get("top_proxies", []):
                prev_top20.append(f"{p['ip']}:{p['port']}")
        except Exception:
            pass
    return tested, prev_top20

def _flush_buffers():
    global _tested_buf, _scores_buf
    if _tested_buf:
        with _tested_lock:
            existing = set()
            if os.path.isfile(TESTED_FILE):
                with open(TESTED_FILE, encoding="utf-8") as f:
                    existing = {line.strip() for line in f if line.strip()}
            with open(TESTED_FILE, "w", encoding="utf-8") as f:
                for line in sorted(existing.union(_tested_buf)):
                    f.write(line + "\n")
        _tested_buf.clear()
    # Keep only the latest score for each proxy. This removes dead/retested
    # proxies from the published list instead of retaining stale append-only rows.
    if _scores_buf or _all_scores:
        with _write_lock:
            with open(BEST_SCORES_FILE, "w", encoding="utf-8") as f:
                for line in _all_scores.values():
                    f.write(line + "\n")
        _scores_buf.clear()
    _rebuild_output_files()

def _rebuild_output_files():
    entries = []
    seen = set()
    if os.path.isfile(BEST_SCORES_FILE):
        with open(BEST_SCORES_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if "|" not in line:
                    continue
                parts = line.split("|", 4)
                if len(parts) < 5:
                    continue
                key = f"{parts[1]}:{parts[2]}"
                if key in seen:
                    continue
                seen.add(key)
                entries.append({
                    "score":   int(parts[0]),
                    "ip":      parts[1],
                    "port":    int(parts[2]),
                    "latency": int(parts[3]),
                    "caps":    parts[4],
                })
    for line in _scores_buf:
        parts = line.split("|", 4)
        if len(parts) < 5:
            continue
        key = f"{parts[1]}:{parts[2]}"
        if key in seen:
            continue
        seen.add(key)
        entries.append({
            "score":   int(parts[0]),
            "ip":      parts[1],
            "port":    int(parts[2]),
            "latency": int(parts[3]),
            "caps":    parts[4],
        })
    entries.sort(key=lambda e: e["score"], reverse=True)
    top20 = [e for e in entries[:20] if e["score"] > 0]
    tested_total = sum(1 for _ in open(TESTED_FILE)) if os.path.isfile(TESTED_FILE) else 0

    with open(VERIFIED_TXT, "w") as f:
        for e in top20:
            f.write(f"socks5h://{e['ip']}:{e['port']}  # score:{e['score']} latency:{e['latency']}ms caps:[{e['caps']}]\n")

    j = {
        "updated_at":      datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "total_pool":      _total,
        "tested_this_run": _scanned,
        "total_tested":    tested_total,
        "top_proxies": [{
            "ip":           e["ip"],
            "port":         e["port"],
            "capabilities": [c.strip() for c in e["caps"].split(",") if c.strip()],
            "latency_min":  e["latency"],
            "score":        e["score"],
        } for e in top20],
    }
    with open(VERIFIED_JSON, "w") as f:
        json.dump(j, f, indent=2)

    with open(README_MD, "w") as f:
        f.write(f"# Verified SOCKS5 Proxies\n> Updated: {j['updated_at']}\n\n## Stats\n")
        f.write(f"- Pool size: {_total}\n- Tested this run: {_scanned}\n")
        f.write(f"- Total tested all runs: {tested_total}\n- In TOP 20: {len(top20)}\n\n")
        f.write("## Subscribe\nTXT: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt\n")
        f.write("JSON: https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.json\n\n")
        f.write("## Score\nBase: (1000 - min_latency) / 10 + 100\n")
        f.write("Each reachable target +20 (google/openai/anthropic/grok — all equal weight)\n\n")
        f.write("## Strategy\n- Parallel fetch from 6 sources\n")
        f.write("- Previous TOP 20 retested first every run\n")
        f.write("- Concurrent probe of all 4 targets per proxy\n")
        f.write("- Success requires a usable HTTP response; 403/407/5xx are rejected\n")
        f.write("- State persisted in data/.tested and data/.best_scores.txt (committed to repo)\n")

def cleanup():
    _flush_buffers()
    log("Final flush complete.")

def sig_handler(sig, frame):
    log(f"Caught signal {sig}, flushing ...")
    cleanup()
    sys.exit(0)

signal.signal(signal.SIGTERM, sig_handler)
signal.signal(signal.SIGINT, sig_handler)
atexit.register(cleanup)

def test_batch(proxies):
    global _scanned, _passed, _tested_buf, _scores_buf

    def test_one(proxy):
        caps, best = probe_all_targets(proxy)
        score = compute_score(best, caps) if caps else 0
        return proxy, caps, best, score

    results = []
    with ThreadPoolExecutor(max_workers=len(proxies)) as ex:
        futures = {ex.submit(test_one, p): p for p in proxies}
        for fut in as_completed(futures):
            try:
                results.append(fut.result())
            except Exception:
                proxy = futures[fut]
                results.append((proxy, [], 99999, 0))

    for proxy, caps, best, score in results:
        _scanned += 1
        _tested_buf.append(proxy)
        if caps:
            _passed += 1
            ip, port = proxy.split(":")
            caps_s = ",".join(caps)
            score_line = f"{score}|{ip}|{port}|{best}|{caps_s}"
            _scores_buf.append(score_line)
            _all_scores[proxy] = score_line
            log(f"  [{_scanned}] [{proxy}] score={score} latency={best}ms caps=[{caps_s}]")
        else:
            log(f"  [{_scanned}] [{proxy}] DEAD (no targets reachable)")
            _all_scores.pop(proxy, None)

    _flush_buffers()

def main():
    global _total, _scanned, _passed

    pool = fetch_all()
    _total = len(pool)

    tested, prev_top20 = load_state()
    log(f"  Already tested: {len(tested)}  |  Previous TOP 20: {len(prev_top20)}")

    retest = [p for p in prev_top20 if p in pool]
    if retest:
        log(f"Step 2: Retesting previous TOP 20 ({len(retest)} proxies) ...")
        for p in retest:
            _all_scores.pop(p, None)
            tested.discard(p)
        test_batch(retest)
        # Keep the in-memory state aligned with the persisted buffer so a
        # proxy retested above is not immediately scanned a second time.
        tested.update(retest)

    new = [p for p in pool if p not in tested]
    log(f"Step 3: Testing new proxies ({len(new)} to test) ...")
    if not new:
        log("  No new proxies. Final flush and exit.")
        _flush_buffers()
        return

    t0 = time.time()
    idx = 0
    while idx < len(new):
        if time.time() - t0 > RUN_LIMIT:
            log(f"  STOP: reached {RUN_LIMIT}s limit, tested {idx} new proxies this run")
            break
        batch = new[idx:idx + BATCH]
        idx += len(batch)
        log(f"  Batch {idx - len(batch) + 1}-{idx} ({len(batch)} proxies) ...")
        test_batch(batch)
        time.sleep(BATCH_GAP)

    log(f"Scan complete: scanned={_scanned}, passed={_passed}")
    log("Done!")
    for fn in sorted(os.listdir(OUTPUT_DIR)):
        fp = os.path.join(OUTPUT_DIR, fn)
        if os.path.isfile(fp):
            st = os.stat(fp)
            log(f"  {OUTPUT_DIR}/{fn}  {st.st_size}B")

if __name__ == "__main__":
    main()

