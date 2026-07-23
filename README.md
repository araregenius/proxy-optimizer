# 🌐 Proxy Optimizer

自动化的 SOCKS5 代理筛选和评分系统，帮你从几千个免费代理中找到**能访问 OpenAI / Anthropic / Grok / Google** 的最优节点。

## 工作原理

```
6 个免费代理源 ──→ GitHub Actions（每2小时） ──→ 输出最优代理列表
     │                    │                          │
     │              • 拉取去重                      │
     │              • 测试4个目标站可达性             │
     │              • 评分排序                       │
     │                    │                          ▼
     │              data/verified.txt        CDN 分发
     │              data/verified.json    (全球加速)
     │                    │
     │                    ▼
     │              你本地运行 local_rank.ps1
     │                    │
     │                    ▼
     │            测你本地的真实延迟
     │            输出最优节点
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

### 1️⃣ GitHub 自动跑（你什么都不用做）

1. Fork 或 clone 这个仓库
2. GitHub Actions 每 2 小时自动跑一次
3. 也可以手动触发：Actions → "Run workflow"

### 2️⃣ 订阅已验证的代理

**TXT 列表（直接可以用）**：
```bash
curl -sL https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt
```

**JSON 详细数据（含能力标签）**：
```bash
curl -sL https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.json
```

### 3️⃣ 本地优选（最推荐）

在 Windows PowerShell 中运行：

```powershell
# 进入脚本目录
cd .\scripts\

# 运行（默认取前10个）
.\local_rank.ps1

# 或指定取前5个
.\local_rank.ps1 -TopN 5
```

脚本会自动：
1. 从 CDN 拉取已验证的代理列表
2. 在本地测试每个代理到 `google.com` 的延迟
3. 按延迟从低到高排序
4. 输出最优代理和 `best_proxy.txt` 文件

### 4️⃣ 在你的程序中使用

```powershell
# 读取最优代理
curl -sL https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt | Select-Object -First 1
# 输出: socks5://1.2.3.4:1080  # 评分:88 ...

# curl 用代理访问
curl -x "socks5://1.2.3.4:1080" https://api.openai.com/... 

# Python 用代理
import requests
proxies = {"http": "socks5://1.2.3.4:1080", "https": "socks5://1.2.3.4:1080"}
requests.get("https://api.openai.com/...", proxies=proxies)
```

## 评分规则

| 测试目标 | 权重 |
|---------|:---:|
| api.openai.com 可达 | ⭐⭐⭐⭐⭐ 最高优先级 |
| api.anthropic.com 可达 | ⭐⭐⭐⭐ |
| generativelanguage.googleapis.com (Grok) 可达 | ⭐⭐⭐⭐ |
| google.com 可达 | ⭐⭐⭐ |

**评分 = 基准分(基于延迟) + 可达站点数 × 15**
- 基准分: `(1000 - 最快延迟ms) / 10`
- 评分越高 = 延迟越低 + 能访问的站点越多

## 输出文件

| 文件 | 说明 |
|------|------|
| `data/verified.txt` | 按评分排序的代理列表，可直接使用 |
| `data/verified.json` | 结构化数据，含能力标签和延迟详情 |
| `data/README.md` | 更新说明和统计数据 |
| `best_proxy.txt` | 本地运行后生成，含本地最优排序 |

## 项目结构

```
proxy-optimizer/
├── .github/
│   └── workflows/
│       └── update.yml          # GitHub Actions 定时任务
├── scripts/
│   ├── fetch_and_test.sh      # GitHub 上跑：拉取→测试→评分→输出
│   └── local_rank.ps1         # 本地跑：拉取→本地测延迟→排序
├── data/                      # 输出目录
└── README.md                  # 本文件
```

## 注意事项

- ⚠️ 免费代理不稳定，列表每小时都在变化
- ⚠️ 不要用来登录任何需要敏感信息的账号
- ⚠️ 如果 GitHub Actions 跑了很久没更新，可能是代理质量差（大部分都测挂了）
- ⚠️ 本地测速更准确反映你的真实网络情况

## License

MIT