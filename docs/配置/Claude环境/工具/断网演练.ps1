# 断网演练（部署验收第 10、11 项）：证明「关 TUN、退出 Clash」时 Claude 和其他程序都连不出去（局域网照常），恢复后自动确认网通了。
# 用法（pwsh 7）：pwsh -NoProfile -File <本脚本> -Pause   不用管理员。-Drill 10 / 11 只跑其中一项，默认两项都跑。
# 先退出全部 Claude（Desktop、Claude Code、VS Code 里的 Claude 面板），检测到还在运行就停下。
# Clash 的开关由用户自己点（规矩：AI 不启停 Clash），脚本在终端里提示「现在关 TUN / 退出 Clash」，用户按回车后它来测。
# 第 9 项「出口挂了」本机不实测，按设计证据验收：2026-11-20 两次用防火墙临时堵出口节点都堵不住
# （TUN 开着时 Clash 内核自带放行，优先级高过防火墙阻断，推测，未导出过滤表核实），堵着期间出口 IP 始终是原海外出口。
# 结果写 %LOCALAPPDATA%\ClaudeNetworkGuard\断网演练\（日志-时间.log、结果-时间.json），不打印出口 IP。
param([ValidateSet('全部', '10', '11')][string] $Drill = '全部', [switch] $Pause)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot '读部署清单.ps1')
. (Join-Path $PSScriptRoot 'Clash内核管道.ps1')

foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'NO_PROXY', 'no_proxy') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$outDir = Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard\断网演练'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $outDir "日志-$stamp.log"
$resultFile = Join-Path $outDir "结果-$stamp.json"
$ports = [ordered]@{ 通用 = (Get-DeployPort 通用); 浏览器 = (Get-DeployPort 浏览器); Desktop = (Get-DeployPort Desktop) }
$result = [ordered]@{ 开始 = (Get-Date).ToString('s'); 第10项 = $null; 第11项 = $null }
$allExternal = @('TUN 海外 gstatic', 'TUN 国内 baidu', 'TUN Claude', 'TUN ipify', 'TUN 直连 IP 1.1.1.1', '端口 CLI', '端口 浏览器', '端口 Desktop', '绑物理网卡直连 223.5.5.5')

function Log([string] $Text) {
  $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $Text
  Write-Host $line
  Add-Content -LiteralPath $logFile -Value $line -Encoding utf8
}

# 一次 curl：Proxy 为空时清掉代理、走 TUN；给了 Proxy 就只走那个端口（此时不能加 --noproxy，否则会绕过代理）。
function Invoke-Probe([string] $Url, [string] $Proxy, [string] $Interface) {
  $a = @('--silent', '--max-time', '8', '--output', 'NUL', '--write-out', '%{http_code}')
  if ($Proxy) { $a += @('--proxy', $Proxy) } else { $a += @('--noproxy', '*') }
  if ($Interface) { $a += @('--interface', $Interface) }
  $code = & curl.exe @a $Url 2>$null
  [pscustomobject]@{ Exit = $LASTEXITCODE; Code = [string]$code; Ok = ($LASTEXITCODE -eq 0 -and [string]$code -match '^[23]') }
}

function Invoke-AllProbes {
  $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -ne 'Mihomo' -and $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1
  $localIp = if ($route) { (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.ifIndex | Select-Object -First 1).IPAddress }
  $p = [ordered]@{}
  $p['TUN 海外 gstatic'] = Invoke-Probe 'https://www.gstatic.com/generate_204'
  $p['TUN 国内 baidu'] = Invoke-Probe 'https://www.baidu.com/'
  $p['TUN Claude'] = Invoke-Probe 'https://claude.ai/cdn-cgi/trace'
  $p['TUN ipify'] = Invoke-Probe 'https://api.ipify.org'
  $p['TUN 直连 IP 1.1.1.1'] = Invoke-Probe 'https://1.1.1.1/cdn-cgi/trace'
  $p['端口 CLI'] = Invoke-Probe 'https://claude.ai/cdn-cgi/trace' ("http://127.0.0.1:{0}" -f $ports.通用)
  $p['端口 浏览器'] = Invoke-Probe 'https://claude.ai/cdn-cgi/trace' ("socks5h://127.0.0.1:{0}" -f $ports.浏览器)
  $p['端口 Desktop'] = Invoke-Probe 'https://claude.ai/cdn-cgi/trace' ("http://127.0.0.1:{0}" -f $ports.Desktop)
  $p['绑物理网卡直连 223.5.5.5'] = if ($localIp) { Invoke-Probe 'https://223.5.5.5/resolve?name=baidu.com' -Interface $localIp } else { [pscustomobject]@{ Exit = -1; Code = '无物理网卡'; Ok = $false } }
  $lanOk = if ($route) { [bool](Test-Connection -TargetName $route.NextHop -Count 2 -Quiet -TimeoutSeconds 2) } else { $false }
  $p['局域网网关'] = [pscustomobject]@{ Exit = 0; Code = $(if ($lanOk) { 'ping 通' } else { 'ping 不通' }); Ok = $lanOk }
  foreach ($k in $p.Keys) { Log ('    {0}: {1}（退出码 {2}，返回 {3}）' -f $k, $(if ($p[$k].Ok) { '通' } else { '不通' }), $p[$k].Exit, $p[$k].Code) }
  $p
}

# 判定：$MustFail 里的必须不通，$MustPass 里的必须通。
function Get-Verdict($Probes, [string[]] $MustFail, [string[]] $MustPass) {
  $bad = @()
  foreach ($k in $MustFail) { if ($Probes[$k].Ok) { $bad += "$k 竟然通了" } }
  foreach ($k in $MustPass) { if (-not $Probes[$k].Ok) { $bad += "$k 不通" } }
  [pscustomobject]@{ Pass = (-not $bad); Problems = $bad }
}

# 恢复确认：2 分钟内 TUN 和 CLI 端口都能到 claude.ai 才算恢复。
function Wait-Recovered([string] $Label) {
  $deadline = (Get-Date).AddMinutes(2)
  while ((Get-Date) -lt $deadline) {
    if ((Invoke-Probe 'https://claude.ai/cdn-cgi/trace').Ok -and (Invoke-Probe 'https://claude.ai/cdn-cgi/trace' ("http://127.0.0.1:{0}" -f $ports.通用)).Ok) {
      Log "  $Label：已恢复，claude.ai 经 TUN 和 CLI 端口都通"; return $true
    }
    Start-Sleep -Seconds 3
  }
  Log "  $Label：2 分钟内没恢复！请检查 Clash Verge 是否开着、TUN 是否开着；还不行按桌面「断网急救说明」做"
  return $false
}

$exitCode = 0
try {
  Log "===== 断网演练开始（日志 $logFile）====="
  $claude = @(Get-Process claude -ErrorAction SilentlyContinue)
  if ($claude) {
    Log ('还有 {0} 个 Claude 进程在运行，请先退出 Claude Desktop、Claude Code 和 VS Code 里的 Claude，再重跑本脚本。' -f $claude.Count)
    $claude | ForEach-Object { Log ('    ' + $_.Path) }
    throw '有 Claude 在运行，演练没有开始'
  }

  Log '① 演练前基线（海外、国内、Claude、三个端口都应该通；绑物理网卡直连应该已经被断网开关拦住）：'
  $base = Invoke-AllProbes
  $v = Get-Verdict $base @('绑物理网卡直连 223.5.5.5') @('TUN 海外 gstatic', 'TUN 国内 baidu', 'TUN Claude', '端口 CLI', '端口 浏览器', '端口 Desktop', '局域网网关')
  if (-not $v.Pass) { Log ('基线不正常，演练不做：' + ($v.Problems -join '；')); throw '基线不正常' }

  if ($Drill -in '全部', '10') {
    Write-Host ''
    Read-Host '② 第 10 项「关 TUN」：请在 Clash Verge 里关闭「虚拟网卡模式（TUN）」，Clash 保持开着；关好后回到这里按回车' | Out-Null
    $tunNow = try { (Invoke-ClashApi '/configs').tun.enable } catch { '读不到' }
    Log "  Clash 报告 TUN 开关：$tunNow"
    Start-Sleep -Seconds 5
    $p10 = Invoke-AllProbes
    $v10 = Get-Verdict $p10 $allExternal @('局域网网关')
    Read-Host '  测完了。请在 Clash Verge 里重新打开 TUN，打开后按回车（脚本会等它恢复，最多 2 分钟）' | Out-Null
    $r10 = Wait-Recovered '第 10 项'
    $result.第10项 = [ordered]@{ 结论 = $(if ($v10.Pass -and $r10) { '通过' } else { '不通过' }); TUN开关 = "$tunNow"; 问题 = $v10.Problems; 恢复 = $r10 }
    Log ('  第 10 项结论：' + $result.第10项.结论 + $(if ($v10.Problems) { '（' + ($v10.Problems -join '；') + '）' }))
  }

  if ($Drill -in '全部', '11') {
    Write-Host ''
    Read-Host '③ 第 11 项「退出 Clash」：请右键托盘里的 Clash Verge →「退出」，等图标消失后按回车' | Out-Null
    Start-Sleep -Seconds 3
    $coreLeft = @(Get-Process verge-mihomo* -ErrorAction SilentlyContinue).Count
    $guiLeft = @(Get-Process clash-verge* -ErrorAction SilentlyContinue).Count
    Log "  退出后还在运行的：界面进程 $guiLeft 个，内核进程 $coreLeft 个"
    $p11 = Invoke-AllProbes
    $v11 = Get-Verdict $p11 $allExternal @('局域网网关')
    Read-Host '  测完了。请重新打开 Clash Verge（开始菜单或桌面图标），确认 TUN 开着，然后按回车（脚本会等它恢复，最多 2 分钟）' | Out-Null
    $r11 = Wait-Recovered '第 11 项'
    $result.第11项 = [ordered]@{ 结论 = $(if ($v11.Pass -and $r11) { '通过' } else { '不通过' }); 退出后界面进程 = $guiLeft; 退出后内核进程 = $coreLeft; 问题 = $v11.Problems; 恢复 = $r11 }
    Log ('  第 11 项结论：' + $result.第11项.结论 + $(if ($v11.Problems) { '（' + ($v11.Problems -join '；') + '）' }))
  }

  $ks = & (Join-Path (Split-Path $PSScriptRoot -Parent) 'Desktop防护\全局断网开关.ps1') -Action Status -Json | ConvertFrom-Json
  Log ('④ 收尾：全局断网开关 ' + $ks.Evidence)
  $result.收尾断网开关 = $ks.Installed
} catch {
  Log ('出错：' + $_.Exception.Message)
  $exitCode = 1
} finally {
  $result.结束 = (Get-Date).ToString('s')
  $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $resultFile -Encoding utf8
  Log "===== 演练结束，结果：$resultFile ====="
  Log '回到 Claude 对话说「演练跑完了」，AI 读日志出结果。'
}
if ($Pause) { Read-Host '按回车关闭' | Out-Null }
exit $exitCode
