# 🌐 Proxy Optimizer

自动化的 SOCKS5 代理筛选和评分系统，从几千个免费代理中找出**能访问 OpenAI / Anthropic / Grok / Google** 的最优节点。

## 工作原理

```
6 个免费代理源 ──→ GitHub Actions（每30分钟） ──→ 输出最优代理列表
     │                    │                          │
     │              • 并发拉取去重                    │
     │              • 并发测试4个目标站可达性           │
     │              • 等权重评分排序                   │
     │              • 优先重测上轮 TOP 20              │
     │                    │                          ▼
     │              data/verified.txt        CDN 分发
     │              data/verified.json    (全球加速)
     │
     ▼
dpangestuw/Free-Proxy
Thordata/awesome-free-proxy-list
vakhov/fresh-proxy-list
gfpcom/free-proxy-list
proxyscrape/free-proxy-list
proxifly/free-proxy-list
```

## 使用方式

### 1️⃣ 直接订阅（什么都不用做）

**TXT 列表**：
```bash
curl -sL https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt
```

**JSON 详细数据（含能力标签和延迟）**：
```bash
curl -sL https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.json
```

### 2️⃣ 在你的程序中使用

**curl**：
```bash
# 取最优代理
BEST=$(curl -sL https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt | head -1 | cut -d' ' -f1)
# 通过代理访问 OpenAI
curl -x "$BEST" https://api.openai.com/...
```

**Python**：
```python
import requests

# 从 CDN 取最优代理
resp = requests.get("https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt")
best = resp.text.split("\n")[0].split(" ")[0]  # socks5://ip:port

proxies = {"http": best, "https": best}
requests.get("https://api.openai.com/...", proxies=proxies)
```

### 3️⃣ 自己 Fork 运行

1. Fork 这个仓库
2. 在仓库 Settings → Actions → General → Workflow permissions 中选择 **Read and write permissions**
3. GitHub Actions 每 30 分钟自动跑一次
4. 也可以手动触发：Actions → "Proxy Update & Test" → "Run workflow"

## 评分规则

**4 个目标，等权重，每个 +20 分：**

| 测试目标 | URL | 权重 |
|---|---|---|
| Google | https://google.com | +20 |
| OpenAI | https://api.openai.com/completions | +20 |
| Anthropic | https://api.anthropic.com/v1/messages | +20 |
| Grok | https://api.x.ai/v1/models | +20 |

> **连通标准**：TCP + TLS 握手成功即算连通（不要求 HTTP 2xx）。只要能到达目标服务器并完成 TLS 握手，就视为可达。

**评分公式**：
- 基准分 = `max(0, (1000 - 最低延迟ms) / 10 + 100)`
- 最终分 = 基准分 + 连通目标数 × 20
- 评分越高 = 延迟越低 + 能访问的站点越多

## 测试策略

| 策略 | 说明 |
|---|---|
| **并发拉取** | 6 个代理源同时拉取，最多等 10 秒 |
| **并发探测** | 每批 30 个代理，每个代理同时测 4 个目标 |
| **优先重测** | 每轮先重测上一轮 TOP 20，活的保留、死的剔除 |
| **批量落地** | 每批 30 个结束后统一写盘，不是每个代理写一次 |
| **持久化去重** | 已测代理永久记录在 `data/.tested`，下次直接跳过 |
| **超时保护** | 24 分钟自动停止，`atexit` + `signal` 兜底保证不丢数据 |

## 输出文件

| 文件 | 说明 |
|---|---|
| `data/verified.txt` | TOP 20 代理列表，按评分排序，可直接使用 |
| `data/verified.json` | 结构化数据，含 IP、端口、能力标签、延迟、评分 |
| `data/README.md` | 统计信息和订阅链接 |
| `data/.tested` | 所有已测代理记录（去重用，提交到仓库） |
| `data/.best_scores.txt` | 所有通过测试的代理评分（跨次累积） |

## 项目结构

```
proxy-optimizer/
├── .github/
│   └── workflows/
│       └── update.yml              # GitHub Actions 定时任务（每30分钟）
├── scripts/
│   └── fetch_and_test.py          # Python 脚本：拉取→并发测试→评分→输出
├── data/                          # 输出目录（自动生成并提交）
│   ├── verified.txt               # TOP 20 代理列表
│   ├── verified.json              # 结构化代理数据
│   ├── README.md                  # 统计信息
│   ├── .tested                    # 已测代理去重记录
│   └── .best_scores.txt           # 评分累积
└── README.md                      # 本文件
```

## GitHub Actions 调度

- **定时触发**：每 30 分钟一次（每小时 00 分和 30 分）
- **手动触发**：Actions 页面 `workflow_dispatch`
- **Push 触发**：`scripts/**` 或 workflow 自身变更时
- **超时限制**：每次运行最多 25 分钟（脚本内部 24 分钟自动停止）

## 注意事项

- ⚠️ 免费代理不稳定，列表随时变化，建议每次使用前重新拉取
- ⚠️ 不要用来传输敏感信息或登录账号
- ⚠️ Fork 后需要手动开启 Workflow permissions（Settings → Actions → General → Read and write permissions）
- ⚠️ CDN 地址中的 `araregenius` 需要替换为你的 GitHub 用户名
- ⚠️ 依赖 `PySocks`，GitHub Actions 的 ubuntu-latest 环境会自动安装

## License

MIT
