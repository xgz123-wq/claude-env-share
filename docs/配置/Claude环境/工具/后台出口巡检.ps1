#requires -Version 7.0
# 后台出口巡检（只读）：计划任务每隔几分钟调一次，发现 Claude 流量可能直连就弹窗提醒；只提醒，不改防火墙、Clash，也不关 Claude。
# 背景：环境卫士和一键总检要人手动点才查；2026-11-10 误切 Clash 全局（GLOBAL=DIRECT）时直连了一段时间才被发现。思路参考 Claude-Cage 的后台定时核对。
# 查三类：
#   出口：三个专用端口各经 claude.ai/cdn-cgi/trace 看 Claude 眼里的国家，不是预期国家（默认 US）就报警；只问 Claude 自己，不访问第三方测 IP 站。
#   Clash 模式：直连模式，或全局模式下 GLOBAL 没选 ACCOUNT-US，报警。
#   防火墙：调同目录上一层的 Anthropic网段直连阻断.ps1（总开关 + 两条网段规则）。
#   官方域名：每天一次调 Clash\检查Claude官方域名.ps1，官方清单出现没归类的新域名就报警（交给模型判断要不要加规则）。
# 弹窗只在「失败项和上次不一样」时弹一次，不会每轮都弹；连不上 Claude、读不到 Clash 只记日志（不会直连，只是用不了）。
# 结果和日志在 %LOCALAPPDATA%\ClaudeNetworkGuard\后台出口巡检\。
#
# 用法（pwsh）：
#   .\后台出口巡检.ps1                         巡检一次（计划任务就这么调）
#   .\后台出口巡检.ps1 -Install [-IntervalMinutes 5]   注册计划任务「Claude后台出口巡检」（要管理员，普通权限跑会给出提权命令）；任务以当前用户普通权限运行、不弹黑窗口
#   .\后台出口巡检.ps1 -Uninstall              删除这个计划任务（同样要管理员）
#   .\后台出口巡检.ps1 -Status                 看计划任务和最近一次结果
#   .\后台出口巡检.ps1 -SimulateLoc CN         假装出口跑到中国，验证会弹窗（不改任何设置，不写入上次结果）
#   .\后台出口巡检.ps1 -SimulateFirewallOff    假装防火墙关了，同上
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
  [Parameter(ParameterSetName = 'Install')][switch] $Install,
  [Parameter(ParameterSetName = 'Install')][ValidateRange(1, 60)][int] $IntervalMinutes = 5,
  [Parameter(ParameterSetName = 'Uninstall')][switch] $Uninstall,
  [Parameter(ParameterSetName = 'Status')][switch] $Status,
  [Parameter(ParameterSetName = 'Run')][string] $ExpectedLoc = 'US',
  [Parameter(ParameterSetName = 'Run')][string] $SimulateLoc,
  [Parameter(ParameterSetName = 'Run')][switch] $SimulateFirewallOff,
  [Parameter(ParameterSetName = 'Run')][switch] $NoPopup
)

$ErrorActionPreference = 'Stop'
$taskName = 'Claude后台出口巡检'
$stateDir = Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard\后台出口巡检'
$stateFile = Join-Path $stateDir '最近结果.json'
$logFile = Join-Path $stateDir '巡检日志.log'
$envRoot = Split-Path $PSScriptRoot -Parent

# ---------- 计划任务管理 ----------
function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# 本机普通权限建、删计划任务都被拒绝（2026-11-11 实测，最简单的任务也一样），所以注册和删除要管理员 PowerShell 7 跑一次；
# 任务本身仍以当前用户、普通权限运行，弹窗才能出现在你的桌面上。
if (($Install -or $Uninstall) -and -not (Test-Admin)) {
  $verb = if ($Install) { '-Install' } else { '-Uninstall' }
  Write-Host '注册或删除计划任务需要管理员权限。在 PowerShell 7 里粘贴下面这行（会弹一次 UAC）：' -ForegroundColor Yellow
  Write-Host ("Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-NoExit','-File','`"{0}`"','{1}'" -f $PSCommandPath, $verb)
  exit 1
}
if ($Install) {
  $pwsh = (Get-Process -Id $PID).Path
  $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
  # conhost --headless：不弹黑窗口（直接用 -WindowStyle Hidden 仍会闪一下）。
  $action = New-ScheduledTaskAction -Execute $conhost -Argument ("--headless `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"")
  $user = "$env:USERDOMAIN\$env:USERNAME"
  $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
  $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($repeat, $logon) -Settings $settings -Principal $principal `
    -Description "每 $IntervalMinutes 分钟只读核对 Claude 三个专用端口的出口、Clash 模式和防火墙；出问题弹窗。脚本：$PSCommandPath" -Force | Out-Null
  Write-Host "已注册计划任务「$taskName」：登录时和之后每 $IntervalMinutes 分钟各跑一次，普通权限、不弹黑窗口。删除用 -Uninstall。" -ForegroundColor Green
  return
}
if ($Uninstall) {
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "已删除计划任务「$taskName」；日志和最近结果仍在 $stateDir" -ForegroundColor Green
  } else {
    Write-Host "没有计划任务「$taskName」，不用删。"
  }
  return
}
if ($Status) {
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($task) {
    $info = $task | Get-ScheduledTaskInfo
    Write-Host ("计划任务：{0}；上次运行 {1}（结果码 {2}）；下次 {3}" -f $task.State, $info.LastRunTime, $info.LastTaskResult, $info.NextRunTime)
  } else {
    Write-Host '计划任务：未注册（用 -Install 注册）' -ForegroundColor Yellow
  }
  if (Test-Path -LiteralPath $stateFile) {
    $last = Get-Content -LiteralPath $stateFile -Raw -Encoding utf8 | ConvertFrom-Json
    Write-Host "最近一次：$($last.Time)  总结论 $($last.Overall)"
    foreach ($item in $last.Items) { Write-Host ("  [{0}] {1}：{2}" -f $item.Status, $item.Item, $item.Evidence) }
  } else {
    Write-Host '最近一次：还没跑过'
  }
  return
}

# ---------- 巡检一次 ----------
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
. (Join-Path $PSScriptRoot '读部署清单.ps1')
. (Join-Path $PSScriptRoot 'Clash内核管道.ps1')

$items = [System.Collections.Generic.List[object]]::new()
function Add-Item([ValidateSet('PASS', 'WARN', 'FAIL')][string] $State, [string] $Item, [string] $Evidence, [string] $IP = '') {
  $items.Add([pscustomobject]@{ Status = $State; Item = $Item; Evidence = $Evidence; IP = $IP })
}

# 1. 三个出口，并行查；单个请求最多 12 秒，失败再试一次（线路慢时偶发握手超时）。
$exits = @(
  [pscustomobject]@{ Name = '通用（Claude Code / VS Code 插件）'; Type = 'http'; Port = (Get-DeployPort 通用) }
  [pscustomobject]@{ Name = '专用 Chrome'; Type = 'socks5h'; Port = (Get-DeployPort 浏览器) }
  [pscustomobject]@{ Name = 'Claude Desktop'; Type = 'http'; Port = (Get-DeployPort Desktop) }
)
$exitResults = $exits | ForEach-Object -ThrottleLimit 3 -Parallel {
  $arguments = @('-sS', '--max-time', '12')
  if ($_.Type -eq 'socks5h') { $arguments += @('--socks5-hostname', "127.0.0.1:$($_.Port)") }
  else { $arguments += @('--proxy', "http://127.0.0.1:$($_.Port)") }
  $arguments += 'https://claude.ai/cdn-cgi/trace'
  $ip = ''; $loc = ''
  foreach ($attempt in 1..2) {
    $body = (& curl.exe @arguments 2>$null | Out-String)
    if ($body -match '(?m)^ip=(\S+)') { $ip = $Matches[1] }
    if ($body -match '(?m)^loc=(\S+)') { $loc = $Matches[1] }
    if ($ip) { break }
  }
  [pscustomobject]@{ Name = $_.Name; Port = $_.Port; IP = $ip; Loc = $loc }
}
foreach ($exit in $exits) {
  $r = $exitResults | Where-Object Name -eq $exit.Name | Select-Object -First 1
  $loc = if ($SimulateLoc) { $SimulateLoc } else { $r.Loc }
  $label = "出口：$($exit.Name) $($exit.Port)"
  if (-not $r.IP) { Add-Item WARN $label '连不上 Claude（Clash 没开或线路慢）；不会因此直连，只是暂时用不了' }
  elseif ($loc -ne $ExpectedLoc) { Add-Item FAIL $label "Claude 看到的国家是 $loc（IP $($r.IP)），应为 $ExpectedLoc；可能在直连或节点不对" $r.IP }
  else { Add-Item PASS $label "$loc（IP $($r.IP)）" $r.IP }
}

# 2. Clash 模式：规则模式正常；全局模式时 GLOBAL 必须选 ACCOUNT-US（11-10 后 JS 已让 GLOBAL 只含它）；直连模式一定漏。
try {
  $mode = [string](Invoke-ClashApi '/configs').mode
  switch ($mode) {
    'rule' { Add-Item PASS 'Clash 模式' '规则模式' }
    'direct' { Add-Item FAIL 'Clash 模式' '直连模式：所有流量都不走代理，Claude 会直连；请切回规则模式' }
    'global' {
      $now = [string](Invoke-ClashApi '/proxies/GLOBAL').now
      if ($now -eq 'ACCOUNT-US') { Add-Item WARN 'Clash 模式' '全局模式，GLOBAL 选的是 ACCOUNT-US：Claude 不会直连，但国内网站也会绕美国；用完切回规则模式' }
      else { Add-Item FAIL 'Clash 模式' "全局模式，GLOBAL 选的是 $now：Claude 流量可能直连；请切回规则模式" }
    }
    default { Add-Item WARN 'Clash 模式' "读到未知模式「$mode」" }
  }
} catch {
  Add-Item WARN 'Clash 模式' ("读不到 Clash 内核：" + $_.Exception.Message)
}

# 3. 防火墙总开关 + 两条网段阻断（同一个脚本，一键总检和卫士 S7 也按它的口径）。
if ($SimulateFirewallOff) {
  Add-Item FAIL '防火墙与网段阻断' 'Windows 防火墙未开启：Domain、Private、Public（模拟）'
} else {
  try {
    $fw = & (Join-Path $envRoot 'Anthropic网段直连阻断.ps1') -Json | ConvertFrom-Json
    if ($fw.Succeeded) { Add-Item PASS '防火墙与网段阻断' '防火墙三个配置文件已开启，两条网段阻断生效' }
    else { Add-Item FAIL '防火墙与网段阻断' $fw.Evidence }
  } catch {
    Add-Item WARN '防火墙与网段阻断' ('检查没跑成：' + $_.Exception.Message)
  }
}

# 4. 官方域名复核：每天一次（抓取失败 1 小时后重试），调 ..\Clash\检查Claude官方域名.ps1，只访问 Anthropic 官方文档。
#    有未归类的新域名算失败（会弹窗），由模型判断是否加进 Clash全局账号通道.js；抓取失败只记日志。
#    只能发现官方清单里写了的域名；官方没写、程序却在连的新域名，这里发现不了。
$domainFile = Join-Path $stateDir '官方域名复核.json'
$domainState = $null
if (Test-Path -LiteralPath $domainFile) {
  try { $domainState = Get-Content -LiteralPath $domainFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { $domainState = $null }
}
$domainDue = (-not $domainState) -or ((Get-Date) - [datetime]$domainState.CheckedAt).TotalHours -ge $(if ($domainState.Exit -eq 2) { 1 } else { 24 })
if ($domainDue -and -not ($SimulateLoc -or $SimulateFirewallOff)) {
  $domainExit = 2; $unclassified = @(); $domainProblem = ''
  try {
    $domainJson = & pwsh -NoProfile -File (Join-Path $envRoot 'Clash\检查Claude官方域名.ps1') 2>&1 | Out-String
    $domainExit = $LASTEXITCODE
    $parsed = $domainJson | ConvertFrom-Json
    $unclassified = @($parsed.Unclassified)
    $domainProblem = (@($parsed.Problems) -join '；')
  } catch {
    $domainProblem = $_.Exception.Message
  }
  $domainState = [pscustomobject]@{ CheckedAt = (Get-Date).ToString('o'); Exit = $domainExit; Unclassified = $unclassified; Problem = $domainProblem }
  $domainState | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $domainFile -Encoding utf8
}
if ($domainState) {
  $when = ([datetime]$domainState.CheckedAt).ToString('MM-dd HH:mm')
  switch ([int]$domainState.Exit) {
    0 { Add-Item PASS '官方域名清单' "全部已归类（$when 查）" }
    1 { Add-Item FAIL '官方域名清单' ("官方清单出现还没归类的域名：" + (@($domainState.Unclassified) -join '、') + "（$when 查）；把这条发给 Claude，判断要不要加进 Clash 规则") }
    default { Add-Item WARN '官方域名清单' "没查成（$when）：$($domainState.Problem)；1 小时后重试" }
  }
}

# ---------- 结论、日志、弹窗 ----------
$now = Get-Date
$fails = @($items | Where-Object Status -eq 'FAIL')
$warns = @($items | Where-Object Status -eq 'WARN')
$overall = if ($fails) { 'FAIL' } elseif ($warns) { 'WARN' } else { 'PASS' }
$signature = (@($fails | ForEach-Object { $_.Item }) | Sort-Object) -join '|'
$simulated = [bool]($SimulateLoc -or $SimulateFirewallOff)

$previous = $null
if (Test-Path -LiteralPath $stateFile) {
  try { $previous = Get-Content -LiteralPath $stateFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { $previous = $null }
}

$logLines = [System.Collections.Generic.List[string]]::new()
$stamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
$prefix = if ($simulated) { "$stamp [模拟]" } else { $stamp }
$logLines.Add("$prefix $overall " + (($items | ForEach-Object { "$($_.Status):$($_.Item)" }) -join '；'))
foreach ($item in @($fails + $warns)) { $logLines.Add("    [$($item.Status)] $($item.Item)：$($item.Evidence)") }
# 出口 IP 变了只记一笔（参考 Cage 的 IP 变化规则）；不弹窗，节点自带的轮换不算问题。
if ($previous -and -not $simulated) {
  foreach ($item in @($items | Where-Object { $_.Status -eq 'PASS' -and $_.IP })) {
    $old = @($previous.Items | Where-Object { $_.Item -eq $item.Item -and $_.IP }) | Select-Object -First 1
    if ($old -and $old.IP -ne $item.IP) { $logLines.Add("    [变化] $($item.Item)：出口 IP $($old.IP) → $($item.IP)") }
  }
}
if ($previous -and $previous.Overall -eq 'FAIL' -and -not $fails -and -not $simulated) { $logLines.Add('    [恢复] 之前的失败项已全部恢复') }
Add-Content -LiteralPath $logFile -Value $logLines -Encoding utf8
# 日志只留最近 3000 行（5 分钟一轮大约 1 周）。
$allLines = @(Get-Content -LiteralPath $logFile -Encoding utf8)
if ($allLines.Count -gt 3000) { Set-Content -LiteralPath $logFile -Value $allLines[-3000..-1] -Encoding utf8 }

$previousSignature = if ($previous) { [string]$previous.FailSignature } else { '' }
$shouldPopup = $fails -and ($simulated -or $signature -ne $previousSignature) -and -not $NoPopup

# 模拟结果不写进「最近结果」，免得下一轮真实巡检把它当成上次状态。
if (-not $simulated) {
  [pscustomobject]@{
    Time          = $now.ToString('yyyy-MM-dd HH:mm:ss zzz')
    Overall       = $overall
    FailSignature = $signature
    Items         = $items
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stateFile -Encoding utf8
}

if ($shouldPopup) {
  $lines = @($fails | ForEach-Object { "● $($_.Item)`n   $($_.Evidence)" })
  $head = if ($simulated) { '【模拟测试，不是真的出问题】' + "`n`n" } else { '' }
  $message = $head + "Claude 后台出口巡检发现问题（$($now.ToString('HH:mm'))）：`n`n" + ($lines -join "`n`n") +
    "`n`n先别用 Claude，处理好后打开环境卫士复查。日志：$logFile"
  # 弹窗放到单独的隐藏进程里，巡检本身不被弹窗卡住；ServiceNotification 让弹窗置顶。
  $quoted = $message.Replace("'", "''")
  $popup = "Add-Type -AssemblyName System.Windows.Forms; [void][System.Windows.Forms.MessageBox]::Show('$quoted', 'Claude 后台出口巡检', 'OK', 'Warning', 'Button1', 'ServiceNotification')"
  $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($popup))
  Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) -WindowStyle Hidden
}

foreach ($item in $items) {
  $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$item.Status]
  Write-Host ("[{0}] {1}：{2}" -f $item.Status, $item.Item, $item.Evidence) -ForegroundColor $color
}
Write-Host "总结论 $overall；$(if ($shouldPopup) { '已弹窗' } elseif ($fails -and $NoPopup) { '带 -NoPopup，不弹窗' } elseif ($fails) { '失败项和上次相同，不重复弹窗' } else { '不弹窗' })" -ForegroundColor DarkGray
if ($fails) { exit 2 } elseif ($warns) { exit 1 } else { exit 0 }
