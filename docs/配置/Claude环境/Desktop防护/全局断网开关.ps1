# 全局断网开关（照经验帖第 4 条，Windows 版）：只有走 TUN 的流量、本机回环和局域网能出网，其余一律拦。
# $CorePaths 放行内核只认 Program Files 路径；Clash Verge 服务模式的内核在 ProgramData，不命中，所以关 TUN 后内核也被拦（2026-11-14 实测，用户要这个效果）。
# Clash 崩溃、被退出、TUN 掉了时整台电脑上不了外网（局域网照常），不会有任何程序用本地网络直连。
# 用法（pwsh 7）：
#   -Action Status    只读，看开关装没装（不用管理员）；加 -Json 只输出一行结果、不写日志（一键总检和后台巡检调）
#   -Action Test      管理员。临时装上（进程退出即自动消失）→ 对比测试 → 撤掉；不改任何常驻设置
#   -Action Install   管理员。先跑 Test，通过才装常驻版；装完再测，不通过自动卸掉
#   -Action Remove    管理员。一键解除（断网急救用）
#   Test/Install/Remove 不是管理员时自己弹一次 UAC（桌面快捷方式就这样用）；Status 不提权。
# 结果写 %LOCALAPPDATA%\ClaudeNetworkGuard\全局断网开关\（最近结果.json、日志.log）。
param(
  [ValidateSet('Status', 'Test', 'Install', 'Remove')][string] $Action = 'Status',
  [string[]] $CorePaths = @('C:\Program Files\Clash Verge\verge-mihomo.exe', 'C:\Program Files\Clash Verge\verge-mihomo-alpha.exe'),
  [string] $TunCidr = '198.18.0.0/16',
  [switch] $Json,
  [switch] $Pause
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot '..\工具\读部署清单.ps1')

$lanV4 = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '224.0.0.0/4', '255.255.255.255/32')
$lanV6 = @('fe80::/10', 'ff00::/8', 'fc00::/7')
$outDir = Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard\全局断网开关'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$logFile = Join-Path $outDir '日志.log'
$resultFile = Join-Path $outDir '最近结果.json'

function Write-Log([string] $Text) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Action, $Text
  Write-Host $line
  Add-Content -LiteralPath $logFile -Value $line -Encoding utf8
}

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 桌面快捷方式不带管理员：Test/Install/Remove 不是管理员时自己弹一次 UAC，在新窗口跑完并停住等回车；Status 永远不提权（总检、巡检静默调）。
if ($Action -ne 'Status' -and -not (Test-Admin)) {
  if ($PSBoundParameters.ContainsKey('CorePaths')) {
    Write-Host '带自定义 -CorePaths 时请在管理员终端里直接运行。'
    if ($Pause) { Read-Host '按回车关闭' | Out-Null }
    exit 1
  }
  $argList = @('-NoProfile', '-File', ('"{0}"' -f $PSCommandPath), '-Action', $Action, '-TunCidr', $TunCidr, '-Pause')
  Write-Host "「$Action」要管理员权限，马上弹一次 UAC，请点「是」；之后在新窗口里进行。"
  try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -ErrorAction Stop }
  catch {
    Write-Host ('没拿到管理员权限（UAC 被拒绝或取消）：' + $_.Exception.Message)
    if ($Pause) { Read-Host '按回车关闭' | Out-Null }
    exit 1
  }
  exit 0
}

Add-Type -LiteralPath (Join-Path $PSScriptRoot '全局断网过滤.cs')
$ks = [ClaudeNetworkGuard.GlobalKillSwitch]

function Get-Installed {
  @($ks::Status() | Where-Object { $_ -and $_.Persistent }).Count
}

# 一次 curl：返回 退出码 和 HTTP 状态码。curl.exe 是 Windows 自带的，不走 PowerShell 别名。
function Invoke-Curl([string[]] $Arguments) {
  $out = & "$env:SystemRoot\System32\curl.exe" -s -o NUL -w '%{http_code}' -m 10 @Arguments 2>$null
  [pscustomobject]@{ Exit = $LASTEXITCODE; Code = [string]$out }
}

# 四项对比测试。绕过 TUN 那一项：把请求绑在 Wi-Fi 的本机地址上、直连国内 223.5.5.5，
# 等于模拟「TUN 掉了 / Clash 退了」时程序走本地网络出去；开关生效时必须被拦。
function Invoke-Checks {
  $port = Get-DeployPort 通用
  $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 |
    Where-Object { $_.InterfaceAlias -ne 'Mihomo' -and $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1
  $localIp = if ($route) { (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.ifIndex | Select-Object -First 1).IPAddress } else { $null }
  $r = [ordered]@{}
  $r.经TUN走海外 = Invoke-Curl @('--noproxy', '*', 'https://www.gstatic.com/generate_204')
  $r.经TUN走国内直连 = Invoke-Curl @('--noproxy', '*', 'https://www.baidu.com/')
  $r.经代理端口到Claude = Invoke-Curl @('-x', "http://127.0.0.1:$port", 'https://claude.ai/cdn-cgi/trace')
  $r.绕过TUN直连 = if ($localIp) { Invoke-Curl @('--noproxy', '*', '--interface', $localIp, 'https://223.5.5.5/resolve?name=baidu.com') } else { [pscustomobject]@{ Exit = -1; Code = '无物理网卡' } }
  $r.局域网网关 = if ($route) { [pscustomobject]@{ Exit = $(if (Test-Connection -TargetName $route.NextHop -Count 1 -Quiet -TimeoutSeconds 2) { 0 } else { 1 }); Code = $route.NextHop } } else { [pscustomobject]@{ Exit = -1; Code = '无网关' } }
  foreach ($k in $r.Keys) { Write-Log ('  {0}: 退出码={1} 返回={2}' -f $k, $r[$k].Exit, $r[$k].Code) }
  $r
}

function Test-Ok($c) { $c.Exit -eq 0 -and $c.Code -match '^[23]' }

function Save-Result($Object) {
  $Object | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultFile -Encoding utf8
}

function Invoke-Test {
  if ((Get-Installed) -gt 0) { throw '常驻开关已经装着，先 -Action Remove 再试装。' }
  $cores = @($CorePaths | Where-Object { Test-Path -LiteralPath $_ })
  if (-not $cores.Count) { throw 'Clash 内核程序一个都没找到：' + ($CorePaths -join '、') }
  Write-Log ('Clash 内核：' + ($cores -join '、'))
  Write-Log '① 装开关前（基线）：'
  $before = Invoke-Checks
  if (-not (Test-Ok $before.经TUN走海外) -or -not (Test-Ok $before.经代理端口到Claude)) {
    throw '装开关前海外就不通（Clash / TUN / 节点有问题），先修好再试装。'
  }
  $session = $ks::Open($true)
  try {
    Write-Log '② 临时装上开关（本进程退出即自动消失）：'
    $null = $ks::Install($session, [string[]]$cores, $TunCidr, [string[]]$lanV4, [string[]]$lanV6)
    Start-Sleep -Seconds 2
    $during = Invoke-Checks
  }
  finally {
    $session.Dispose()
    Write-Log '③ 临时开关已撤掉。'
  }
  Start-Sleep -Seconds 2
  Write-Log '④ 撤掉后复查：'
  $after = Invoke-Checks
  $verdict = [ordered]@{
    开关在时海外照常 = (Test-Ok $during.经TUN走海外)
    开关在时国内照常 = (Test-Ok $during.经TUN走国内直连)
    开关在时Claude照常 = (Test-Ok $during.经代理端口到Claude)
    开关在时绕过TUN被拦 = ($during.绕过TUN直连.Exit -ne 0)
    基线绕过TUN能通 = (Test-Ok $before.绕过TUN直连)
    开关在时局域网同基线 = ($during.局域网网关.Exit -eq $before.局域网网关.Exit)
    撤掉后海外恢复 = (Test-Ok $after.经TUN走海外)
    撤掉后Claude恢复 = (Test-Ok $after.经代理端口到Claude)
  }
  $pass = -not @($verdict.Values | Where-Object { -not $_ }).Count
  foreach ($k in $verdict.Keys) { Write-Log ('  判定 {0} = {1}' -f $k, $verdict[$k]) }
  Write-Log ('试装结论：' + $(if ($pass) { '通过' } else { '不通过' }))
  [pscustomobject]@{ Pass = $pass; Verdict = $verdict; Before = $before; During = $during; After = $after; Cores = $cores }
}

# 总检和巡检用：只读 9 条常驻过滤在不在，不写日志（巡检每 5 分钟跑，写日志会越积越多）。
if ($Json -and $Action -eq 'Status') {
  $persistent = @($ks::Status() | Where-Object { $_ -and $_.Persistent }).Count
  $evidence = if ($persistent -eq 9) { '9 条常驻过滤都在：Clash/TUN 不在时整机无外网' }
    elseif ($persistent -eq 0) { '没装（或被急救命令解除了）：Clash/TUN 不在时其他程序会直连；双击桌面「全局断网开关-安装」图标重装' }
    else { "只剩 $persistent/9 条常驻过滤，开关不完整；双击桌面「全局断网开关-安装」图标重装" }
  [pscustomobject]@{ Succeeded = ($persistent -eq 9); Installed = $persistent; Evidence = $evidence } | ConvertTo-Json -Compress
  return
}

$result = $null
try {
  Write-Log "===== 开始 $Action ====="
  switch ($Action) {
    'Status' {
      $s = @($ks::Status())
      $n = @($s | Where-Object { $_ }).Count
      Write-Log ('已装 {0}/9 条过滤；常驻 {1} 条' -f $n, @($s | Where-Object { $_ -and $_.Persistent }).Count)
      $s | Where-Object { $_ } | ForEach-Object { Write-Log ('  ' + $_.Name) }
      $result = [pscustomobject]@{ Action = 'Status'; Installed = $n; At = (Get-Date).ToString('s') }
    }
    'Test' {
      if (-not (Test-Admin)) { throw '需要管理员权限。' }
      $t = Invoke-Test
      $result = [pscustomobject]@{ Action = 'Test'; Pass = $t.Pass; Test = $t; At = (Get-Date).ToString('s') }
      Save-Result $result
    }
    'Install' {
      if (-not (Test-Admin)) { throw '需要管理员权限。' }
      $t = Invoke-Test
      if (-not $t.Pass) {
        $result = [pscustomobject]@{ Action = 'Install'; Installed = $false; Reason = '试装不通过，没有安装'; Test = $t; At = (Get-Date).ToString('s') }
        Save-Result $result
        throw '试装不通过，没有安装常驻开关。详见日志。'
      }
      Write-Log '⑤ 试装通过，安装常驻开关：'
      $persist = $ks::Open($false)
      try { $null = $ks::Install($persist, [string[]]$t.Cores, $TunCidr, [string[]]$lanV4, [string[]]$lanV6) } finally { $persist.Dispose() }
      Start-Sleep -Seconds 2
      Write-Log '⑥ 常驻开关装上后复测：'
      $final = Invoke-Checks
      $ok = (Test-Ok $final.经TUN走海外) -and (Test-Ok $final.经代理端口到Claude) -and (Test-Ok $final.经TUN走国内直连) -and ($final.绕过TUN直连.Exit -ne 0)
      if (-not $ok) {
        Write-Log '复测不通过，自动卸掉常驻开关。'
        $removed = $ks::Remove()
        Write-Log ('已卸掉 {0} 条。' -f $removed)
      }
      $result = [pscustomobject]@{ Action = 'Install'; Installed = $ok; Test = $t; Final = $final; At = (Get-Date).ToString('s') }
      Save-Result $result
      Write-Log ('安装结论：' + $(if ($ok) { '已安装并复测通过' } else { '复测不通过，已自动卸掉' }))
    }
    'Remove' {
      if (-not (Test-Admin)) { throw '需要管理员权限。' }
      $removed = $ks::Remove()
      Write-Log ('已解除，删掉 {0} 条过滤。' -f $removed)
      $result = [pscustomobject]@{ Action = 'Remove'; Removed = $removed; At = (Get-Date).ToString('s') }
      Save-Result $result
    }
  }
}
catch {
  Write-Log ('出错：' + $_.Exception.Message)
  if ($Pause) { Read-Host '按回车关闭' | Out-Null }
  exit 1
}
if ($Pause) { Read-Host '按回车关闭' | Out-Null }
exit 0
