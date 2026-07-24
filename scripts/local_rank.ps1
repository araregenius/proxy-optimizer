# ============================================================
# local_rank.ps1 — 本地代理优选脚本
# 功能: 从 GitHub 拉取已验证代理列表 → 本地测延迟 → 输出最优代理
# 用法: 在 PowerShell 中直接运行  .\local_rank.ps1
# ============================================================

param(
    [int]$TopN = 10,
    [string]$Url = "https://cdn.jsdelivr.net/gh/araregenius/proxy-optimizer/main/data/verified.txt"
)

Write-Host "" -ForegroundColor Cyan
Write-Host "🌐 Proxy Optimizer — 本地代理优选" -ForegroundColor Cyan
Write-Host "=" * 50 -ForegroundColor Cyan

# Step 1: 拉取列表
Write-Host "`n[1/3] 拉取已验证代理列表..." -ForegroundColor Yellow
try {
    $raw = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
    $text = $raw.Content
} catch {
    Write-Host "❌ 拉取失败: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Step 2: 解析代理行
Write-Host "[2/3] 解析代理（去备注、去空行）..." -ForegroundColor Yellow
$lines = $text -split "`n" | Where-Object { $_ -match 'socks5://[^#]+' }
$proxies = @()
foreach ($line in $lines) {
    $proxy = ($line -split '  #')[0].Trim()
    if ($proxy) { $proxies += $proxy }
}
Write-Host "  解析到 $($proxies.Count) 个代理" -ForegroundColor Gray

if ($proxies.Count -eq 0) {
    Write-Host "❌ 没有可测试的代理，请先在 GitHub 运行一次 Actions" -ForegroundColor Red
    exit 1
}

# Step 3: 本地测延迟
Write-Host "`n[3/3] 本地测延迟..." -ForegroundColor Yellow
$results = @()

for ($i = 0; $i -lt $proxies.Count; $i++) {
    $proxy = $proxies[$i]
    $ipPort = $proxy -replace 'socks5://', ''

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $latency = 9999
    try {
        # Use curl.exe (Windows 10+ built-in) which natively supports SOCKS5
        $result = & curl.exe -s -o nul -w '%{http_code}' --socks5 "$ipPort" --max-time 5 'https://google.com' 2>$null
        $sw.Stop()
        $latency = $sw.ElapsedMilliseconds
        if ($result -match '^[234]') {
            $results += @{ Proxy=$proxy; IP=($ipPort -split ':')[0]; Port=($ipPort -split ':')[1]; Latency=$latency; Status='✅' }
        } else {
            $latency = 9999
            $results += @{ Proxy=$proxy; IP=($ipPort -split ':')[0]; Port=($ipPort -split ':')[1]; Latency=9999; Status='❌' }
        }
    } catch {
        $sw.Stop()
        $results += @{ Proxy=$proxy; IP=($ipPort -split ':')[0]; Port=($ipPort -split ':')[1]; Latency=9999; Status='❌' }
    }

    $pct = [math]::Round(($i + 1) / $proxies.Count * 100)
    Write-Host "  [$($i+1)/$($proxies.Count)] $proxy -> $($latency)ms ($pct%)" -ForegroundColor Gray
}

# Step 4: 排序 & 输出
Write-Host "`n" -ForegroundColor Cyan
Write-Host "📊 结果排序（延迟从低到高）" -ForegroundColor Cyan
Write-Host "=" * 50 -ForegroundColor Cyan

$sorted = $results | Sort-Object Latency
$passCount = ($sorted | Where-Object { $_.Latency -lt 9000 }).Count

Write-Host "  可用代理: $passCount / $($results.Count)`n" -ForegroundColor Gray

Write-Host "  #   延迟(ms)    IP               Port     状态"
Write-Host "  -" * 45

for ($i = 0; $i -lt [Math]::Min($TopN, $sorted.Count); $i++) {
    $r = $sorted[$i]
    $rank = if ($i -eq 0) { '🥇' } elseif ($i -eq 1) { '🥈' } elseif ($i -eq 2) { '🥉' } else { "$i" }
    $color = switch ($i) { 0 { 'Green' }; 1 { 'Yellow' }; 2 { 'Cyan' }; default { 'Gray' } }
    Write-Host "  $rank  $($r.Latency.PadRight(8))  $($r.IP.PadRight(15))  $($r.Port.PadRight(5))  $($r.Status)" -ForegroundColor $color
}

Write-Host "  -" * 45

# Step 5: 输出最优
if ($sorted.Count -gt 0 -and $sorted[0].Latency -lt 9000) {
    Write-Host "`n⚡ 最优代理: $($sorted[0].Proxy) (延迟: $($sorted[0].Latency)ms)" -ForegroundColor Green
    $sorted | ForEach-Object { $_.Proxy } | Set-Content "best_proxy.txt" -Encoding UTF8
    Write-Host "  已保存到: best_proxy.txt" -ForegroundColor Gray
} else {
    Write-Host "`n⚠️  没有找到可用的代理" -ForegroundColor Yellow
}

Write-Host "`n✅ 完成!" -ForegroundColor Green