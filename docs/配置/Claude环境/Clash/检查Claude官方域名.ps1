#requires -Version 7.0
<#
只读检查：抓 Anthropic 官方两份网络要求（Markdown 版），提取域名，与本机 Claude 路由清单比对。
不读不改 Clash、不启动任何程序；只做 HTTPS GET 官方文档。运行方式：pwsh -NoProfile -File <本脚本>。
退出码：0 全部已归类（可保持安静）；1 有未归类新域名（需模型判断）；2 抓取或解析失败、脚本自身出错（需人处理）。
归类：已被本机 Claude 域名后缀或精确域名覆盖 / 在下方共享域名清单（精确匹配）/ 未归类。
Dropped 列出被当作非域名丢弃的词，供人工扫一眼；文档改版导致漏提时，通常先体现在 HostCount 明显下降。
新域名判断后：Claude 专属 → 只改 Clash全局账号通道.js 的规则清单（由用户重载）；共享第三方 → 加入下方 $sharedHosts 并写明原因。
#>
param(
  [string] $OfflineDir  # 测试用：目录内放 network-config.md、desktop.md，不联网
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

try {
  . (Join-Path (Split-Path $PSScriptRoot -Parent) '工具\读Claude规则.ps1')

  # 共享或可选的第三方域名：官方清单里出现，但不绑定 ACCOUNT-US（原因见 说明\排障与变更.md 第 7.3 节）。
  # 一律精确匹配，避免把同一后缀下的 Claude 专属子域误当共享。
  $sharedHosts = @(
    'github.com', 'raw.githubusercontent.com', 'registry.npmjs.org', 'storage.googleapis.com',
    'formulae.brew.sh', 'googlesource.com',
    'browser-intake-us5-datadoghq.com',
    'fonts.googleapis.com', 'fonts.gstatic.com',
    'cdnjs.cloudflare.com', 'cdn.jsdelivr.net', 'cdn.tailwindcss.com', 'code.jquery.com', 'unpkg.com'
  )
  $minHosts = 15  # 当前两份文档各约 25 个；低于此值说明文档结构可能变了

  $sources = @(
    @{ Name = 'Claude Code'; File = 'network-config.md'; Url = 'https://code.claude.com/docs/en/network-config.md' },
    @{ Name = 'Desktop';     File = 'desktop.md';        Url = 'https://code.claude.com/docs/en/desktop.md' }
  )
  $headingPattern = '^(#{2,3})\s+Network access requirements\s*$'

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
      if ($end -le $i + 1) { return $null }
      return $Lines[($i + 1)..($end - 1)]
    }
    return $null
  }

  # 取代码块内每一行和行内反引号词；清掉列表符、注释、协议、端口、路径后判断是不是域名
  function Get-Hosts([string[]] $Section) {
    $hostRegex = '^\*?[a-z0-9-]*\.?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'
    $notHostTld = @('json', 'md', 'js', 'ts', 'py', 'yaml', 'yml', 'txt', 'toml', 'exe', 'html')
    $tokens = New-Object System.Collections.Generic.List[string]
    $fence = $null
    foreach ($line in $Section) {
      $f = [regex]::Match($line, '^\s*(```+|~~~+)')
      if ($f.Success) {
        if ($null -eq $fence) { $fence = $f.Groups[1].Value[0] } elseif ($f.Groups[1].Value[0] -eq $fence) { $fence = $null }
        continue
      }
      if ($null -ne $fence) { $tokens.Add($line); continue }
      foreach ($m in [regex]::Matches($line, '`([^`\s]+)`')) { $tokens.Add($m.Groups[1].Value) }
    }
    $hosts = New-Object System.Collections.Generic.List[string]
    $dropped = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
      $x = ($t -replace '\s+#.*$', '' -replace '^\s*[-*+]\s+', '').Trim().ToLowerInvariant()
      $x = $x -replace '^[a-z]+://', '' -replace '[/:?].*$', ''
      if (-not $x) { continue }
      if ($x -notmatch $hostRegex -or $x.Split('.')[-1] -in $notHostTld) { if ($t.Trim() -match '\.') { $dropped.Add($t.Trim()) }; continue }
      $hosts.Add(($x -replace '^\*[^.]*\.', ''))
    }
    return [pscustomobject]@{ Hosts = @($hosts | Sort-Object -Unique); Dropped = @($dropped | Sort-Object -Unique) }
  }

  function Test-Suffix([string] $HostName, [string[]] $Suffixes) {
    foreach ($s in $Suffixes) { if ($HostName -eq $s -or $HostName.EndsWith('.' + $s)) { return $true } }
    return $false
  }

  # 本机清单只有一份：Clash全局账号通道.js。
  # 精确入组的域名也算已覆盖，如 http-intake.logs.us5.datadoghq.com：同后缀的其他 Datadog 域名不入组。
  $claudeList = Get-ClaudeRuleList
  $jsDns = @($claudeList.Suffixes.Value)
  $jsExact = @($claudeList.Exact.Value)

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
      $section = Get-Section ($md -split "`r?`n") $headingPattern
      if (-not $section) { throw '找不到 Network access requirements 小节，文档结构可能已变' }
      $parsed = Get-Hosts $section
      $hosts = $parsed.Hosts
      if ($hosts.Count -lt $minHosts) { throw "只解析出 $($hosts.Count) 个域名（下限 $minHosts），文档结构可能已变" }
      $covered = @($hosts | Where-Object { (Test-Suffix $_ $jsDns) -or $_ -in $jsExact })
      $shared = @($hosts | Where-Object { $_ -notin $covered -and $_ -in $sharedHosts })
      $new = @($hosts | Where-Object { $_ -notin $covered -and $_ -notin $sharedHosts })
      $unclassified += $new | ForEach-Object { '{0}: {1}' -f $src.Name, $_ }
      $reports += [pscustomobject]@{ Source = $src.Name; Url = $src.Url; HostCount = $hosts.Count; Covered = $covered.Count; Shared = $shared.Count; Unclassified = $new; Dropped = $parsed.Dropped }
    } catch {
      $problems += ('{0}: {1}' -f $src.Name, $_.Exception.Message)
    }
  }

  $status = if ($problems) { 'attention' } elseif ($unclassified) { 'new-hosts' } else { 'ok' }
  [pscustomobject]@{
    CheckedAt    = (Get-Date -Format o)
    Status       = $status
    Sources      = $reports
    Unclassified = $unclassified
    Problems     = $problems
  } | ConvertTo-Json -Depth 6

  if ($problems) { exit 2 }
  if ($unclassified) { exit 1 }
  exit 0
} catch {
  [pscustomobject]@{ CheckedAt = (Get-Date -Format o); Status = 'attention'; Problems = @('脚本自身出错：' + $_.Exception.Message) } | ConvertTo-Json -Depth 3
  exit 2
}
