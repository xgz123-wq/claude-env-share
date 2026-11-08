#requires -Version 7.0
# 只读：关掉 Claude Desktop 之后，查任务管理器里还剩哪些「Claude」进程、各是什么、有没有联网。
# 结果同时存一份到 %LOCALAPPDATA%\ClaudeNetworkGuard\残留进程快照\，重新打开 Claude 后可让 Claude 读这份快照。
# 不结束进程、不改服务、不联网、不提权。运行：pwsh -NoProfile -File <本脚本>
[CmdletBinding()]
param(
  # 先等几秒再查，方便「先跑脚本、再关 Claude」
  [int]$WaitSeconds = 0
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

if ($WaitSeconds -gt 0) {
  Write-Host "等 $WaitSeconds 秒，现在去关 Claude Desktop ..."
  Start-Sleep -Seconds $WaitSeconds
}

$all = @(Get-CimInstance Win32_Process)
$byId = @{}; foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
$services = @(Get-CimInstance Win32_Service)
$svcByPid = @{}; foreach ($s in $services) { if ($s.ProcessId) { $svcByPid[[int]$s.ProcessId] = $s } }

function Get-Kind($p) {
  $path = [string]$p.ExecutablePath
  $svc = $svcByPid[[int]$p.ProcessId]
  if ($svc) { return "系统服务 $($svc.Name)（开机自启，不属于 Desktop）" }
  if ($p.Name -match '^cowork') { return 'Cowork 后台组件' }
  if ($path -match '\\WindowsApps\\Claude_[^\\]+\\app\\Claude\.exe$') {
    $parent = $byId[[int]$p.ParentProcessId]
    if ($parent -and $parent.Name -ieq 'claude.exe') { return 'Desktop 子进程（窗口/渲染/GPU 等）' }
    return 'Desktop 主进程'
  }
  if ($path -match '\\AppData\\Roaming\\Claude\\claude-code\\') { return 'Desktop 内置的 Claude Code 会话' }
  if ($p.Name -ieq 'claude.exe') { return 'Claude Code CLI 或其他 claude.exe' }
  return '其他（路径含 claude/anthropic）'
}

$hits = @($all | Where-Object {
  $_.ProcessId -ne $PID -and (
    $_.Name -match 'claude|cowork' -or
    ([string]$_.ExecutablePath) -match 'claude|anthropic' -or
    ($svcByPid.ContainsKey([int]$_.ProcessId) -and $svcByPid[[int]$_.ProcessId].PathName -match 'claude|anthropic')
  )
} | Sort-Object CreationDate)

$tcp = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("查 Claude 残留进程  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add('')

if (-not $hits) {
  $lines.Add('结论：没有任何 Claude 相关进程，退得很干净。')
} else {
  $rows = foreach ($p in $hits) {
    $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
    $remote = @($tcp | Where-Object {
      $_.OwningProcess -eq $p.ProcessId -and $_.State -eq 'Established' -and
      $_.RemoteAddress -notmatch '^(127\.|::1$|0\.0\.0\.0$|::$)'
    } | ForEach-Object { "$($_.RemoteAddress):$($_.RemotePort)" } | Select-Object -Unique)
    [pscustomobject]@{
      PID      = $p.ProcessId
      父PID    = $p.ParentProcessId
      名字     = $p.Name
      启动时间 = '{0:MM-dd HH:mm:ss}' -f $p.CreationDate
      内存MB   = if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB) } else { '' }
      是什么   = Get-Kind $p
      对外连接 = if ($remote) { $remote -join ' ' } else { '无' }
    }
  }
  # 一个进程两行，窄窗口也不会把表头挤乱
  foreach ($r in $rows) {
    $lines.Add("● $($r.是什么)")
    $lines.Add("  $($r.名字)  PID $($r.PID)（父 $($r.父PID)）  启动 $($r.启动时间)  内存 $($r.内存MB)MB  对外连接：$($r.对外连接)")
  }
  $lines.Add('')

  $desktop = @($rows | Where-Object { $_.是什么 -like 'Desktop*' })
  $svcOnly = @($rows | Where-Object { $_.是什么 -like '系统服务*' })
  $net = @($rows | Where-Object { $_.对外连接 -ne '无' })
  if ($desktop) { $lines.Add("结论：Desktop 还有 $($desktop.Count) 个进程没退出（真残留），把这份结果给 Claude 看。") }
  elseif ($svcOnly.Count -eq $rows.Count) { $lines.Add('结论：Desktop 已退干净；剩下的只是开机自启的系统服务，不是 Desktop 没关掉。') }
  else { $lines.Add('结论：Desktop 已退干净，但还有其他 Claude 相关进程，见上表「是什么」一列。') }
  if ($net) { $lines.Add("注意：有 $($net.Count) 个进程有对外连接，见「对外连接」一列。") }
  else { $lines.Add('联网：没有进程直接连外网（走本机 Clash 代理的连接不算在内）。') }
}

$svc = $services | Where-Object { $_.PathName -match 'claude|anthropic|cowork' }
foreach ($s in $svc) {
  $lines.Add("服务 $($s.Name)（显示名「$($s.DisplayName)」）：状态 $($s.State)，启动方式 $($s.StartMode)，账户 $($s.StartName)")
}

$text = $lines -join [Environment]::NewLine
Write-Host $text

$outDir = Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard\残留进程快照'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outFile = Join-Path $outDir ("{0:yyyyMMdd-HHmmss}.txt" -f (Get-Date))
Set-Content -LiteralPath $outFile -Value $text -Encoding utf8
Write-Host ''
Write-Host "已存快照：$outFile"
