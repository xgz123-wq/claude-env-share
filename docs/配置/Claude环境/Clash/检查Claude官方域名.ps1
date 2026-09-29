#requires -Version 7.0
<#
只读检查：抓 Anthropic 官方两份网络要求（Markdown 版），提取域名，与本机 Claude 路由清单比对。
不读不改 Clash、不启动任何程序；只做 HTTPS GET 官方文档。
退出码：0 全部已归类（可保持安静）；1 有未归类新域名（需模型判断）；2 抓取或解析失败、本地清单不一致（需人处理）。
归类：已被本机 Claude 域名后缀覆盖 / 在下方共享域名清单 / 未归类。
新域名判断后：Claude 专属 → 走变更流程加入 Clash全局账号通道.js 与验证脚本；共享第三方 → 加入下方 $sharedHosts 并写明原因。
#>
param(
  [string] $OfflineDir  # 测试用：目录内放 network-config.md、desktop.md，不联网
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$clashDir = $PSScriptRoot
$routeScript = Join-Path $clashDir 'Clash全局账号通道.js'
$verifyScript = Join-Path $clashDir '验证Clash账号专用通道.ps1'

# 共享或可选的第三方域名：官方清单里出现，但不绑定 ACCOUNT-US（原因见 DNS分层说明「Claude 域名定期复核」）
$sharedHosts = @(
  'github.com', 'raw.githubusercontent.com', 'registry.npmjs.org', 'storage.googleapis.com',
  'formulae.brew.sh', 'googlesource.com',
  'datadoghq.com', 'browser-intake-us5-datadoghq.com',
  'fonts.googleapis.com', 'fonts.gstatic.com',
  'cdnjs.cloudflare.com', 'cdn.jsdelivr.net', 'cdn.tailwindcss.com', 'code.jquery.com', 'unpkg.com'
)

$sources = @(
  @{ Name = 'Claude Code'; File = 'network-config.md'; Url = 'https://code.claude.com/docs/en/network-config.md'; Heading = '^(#{2,3})\s+Network access requirements\s*$' },
  @{ Name = 'Desktop';     File = 'desktop.md';        Url = 'https://code.claude.com/docs/en/desktop.md';        Heading = '^(#{2,3})\s+Network access requirements\s*$' }
)

function Get-BlockItems([string] $Text, [string] $Name) {
  $m = [regex]::Match($Text, '(?s)' + [regex]::Escape($Name) + '\s*=\s*[@\[]\(?(.*?)[\)\]]\s*[;\r\n]')
  if (-not $m.Success) { throw "无法在脚本里定位列表 $Name" }
  return $m.Groups[1].Value
}

function Get-Section([string[]] $Lines, [string] $HeadingPattern) {
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    $h = [regex]::Match($Lines[$i], $HeadingPattern)
    if (-not $h.Success) { continue }
    $level = $h.Groups[1].Value.Length
    $end = $Lines.Count
    for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
      $n = [regex]::Match($Lines[$j], '^(#{1,6})\s')
      if ($n.Success -and $n.Groups[1].Value.Length -le $level) { $end = $j; break }
    }
    return $Lines[($i + 1)..($end - 1)]
  }
  return $null
}

function Get-Hosts([string[]] $Section) {
  $hostRegex = '^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  $notHostTld = @('json', 'md', 'js', 'ts', 'py', 'sh', 'yaml', 'yml', 'txt', 'toml', 'exe', 'html')
  $tokens = New-Object System.Collections.Generic.List[string]
  $inFence = $false
  foreach ($line in $Section) {
    if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
    if ($inFence) { $tokens.Add($line.Trim()); continue }
    foreach ($m in [regex]::Matches($line, '`([^`\s]+)`')) { $tokens.Add($m.Groups[1].Value) }
  }
  $hosts = foreach ($t in $tokens) {
    $x = $t.ToLowerInvariant()
    if ($x -notmatch $hostRegex) { continue }
    if ($x.Split('.')[-1] -in $notHostTld) { continue }
    $x -replace '^\*\.', ''
  }
  return @($hosts | Sort-Object -Unique)
}

function Test-Suffix([string] $HostName, [string[]] $Suffixes) {
  foreach ($s in $Suffixes) { if ($HostName -eq $s -or $HostName.EndsWith('.' + $s)) { return $true } }
  return $false
}

# 本机清单：以路由脚本为准，同时核对四处来源是否一致
$routeText = Get-Content -LiteralPath $routeScript -Raw
$verifyText = Get-Content -LiteralPath $verifyScript -Raw
$jsDns = @([regex]::Matches((Get-BlockItems $routeText 'var accountDnsDomains'), '"\+\.([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$jsRule = @([regex]::Matches((Get-BlockItems $routeText 'var claudeRuleMatchers'), '"DOMAIN-SUFFIX,([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$vfDns = @([regex]::Matches((Get-BlockItems $verifyText '$requiredClaudeDnsDomains'), "'\+\.([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$vfRule = @([regex]::Matches((Get-BlockItems $verifyText '$requiredClaudeRules'), "'DOMAIN-SUFFIX,([^,']+),ACCOUNT-US'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$localMismatch = @()
foreach ($pair in @(@('路由脚本 DNS', $jsDns), @('路由脚本 规则', $jsRule), @('验证脚本 DNS', $vfDns), @('验证脚本 规则', $vfRule))) {
  $diff = Compare-Object $jsDns $pair[1]
  if ($diff) { $localMismatch += ('{0} 与路由脚本 DNS 清单不一致：{1}' -f $pair[0], (($diff | ForEach-Object { $_.InputObject + $(if ($_.SideIndicator -eq '<=') { '(仅路由DNS)' } else { '(仅此处)' }) }) -join ', ')) }
}

$problems = @()
$reports = @()
$unclassified = @()
foreach ($src in $sources) {
  try {
    if ($OfflineDir) {
      $md = Get-Content -LiteralPath (Join-Path $OfflineDir $src.File) -Raw
    } else {
      $md = (& curl.exe --silent --show-error --fail --location --max-time 30 --retry 2 $src.Url 2>&1) -join "`n"
      if ($LASTEXITCODE -ne 0) { throw "下载失败：$md" }
    }
    $section = Get-Section ($md -split "`r?`n") $src.Heading
    if (-not $section) { throw '找不到 Network access requirements 小节，文档结构可能已变' }
    $hosts = Get-Hosts $section
    if ($hosts.Count -lt 5) { throw "只解析出 $($hosts.Count) 个域名，文档结构可能已变" }
    $covered = @($hosts | Where-Object { Test-Suffix $_ $jsDns })
    $shared = @($hosts | Where-Object { -not (Test-Suffix $_ $jsDns) -and (Test-Suffix $_ $sharedHosts) })
    $new = @($hosts | Where-Object { -not (Test-Suffix $_ $jsDns) -and -not (Test-Suffix $_ $sharedHosts) })
    $unclassified += $new | ForEach-Object { '{0}: {1}' -f $src.Name, $_ }
    $reports += [pscustomobject]@{ Source = $src.Name; Url = $src.Url; HostCount = $hosts.Count; Covered = $covered.Count; Shared = $shared.Count; Unclassified = $new }
  } catch {
    $problems += ('{0}: {1}' -f $src.Name, $_.Exception.Message)
  }
}

$status = if ($problems -or $localMismatch) { 'attention' } elseif ($unclassified) { 'new-hosts' } else { 'ok' }
[pscustomobject]@{
  CheckedAt     = (Get-Date -Format o)
  Status        = $status
  Sources       = $reports
  Unclassified  = $unclassified
  LocalMismatch = $localMismatch
  Problems      = $problems
} | ConvertTo-Json -Depth 6

if ($problems -or $localMismatch) { exit 2 }
if ($unclassified) { exit 1 }
exit 0
