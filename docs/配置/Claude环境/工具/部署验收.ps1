# 部署验收（只读）：按 部署提示词.md「怎么算做好了」第 1~9 项实测，走虚拟网卡（清掉代理变量、--noproxy），用 Clash 连接记录证明走了哪条规则、哪个组。
# 第 9 项只核设计证据（TUN 开着时堵不住节点，见 断网演练.ps1 头注释）；第 10、11 项会断网，用 工具/断网演练.ps1。
# 用法（pwsh 7，不用管理员）：pwsh -NoProfile -File <本脚本>     不打印出口 IP，只写「相同 / 不同」和国家。退出码：0 全过，1 有 FAIL。
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot '读部署清单.ps1')
$allowedCountries = Get-DeployExitCountries
. (Join-Path $PSScriptRoot 'Clash内核管道.ps1')
foreach ($v in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'NO_PROXY', 'no_proxy') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$group = 'ACCOUNT-US'
$script:results = @()

function Add-Result([string] $Status, [string] $Item, [string] $Evidence) {
  $script:results += [pscustomobject]@{ Status = $Status; Item = $Item; Evidence = $Evidence }
  Write-Host ('[{0,-4}] {1}' -f $Status, $Item)
  Write-Host ('       ' + $Evidence)
}

# 走 TUN 发一次请求，请求进行中从连接记录里抓命中的规则和组。
function Invoke-TunProbe([string] $Target, [string] $Url) {
  $out = Join-Path $env:TEMP ('部署验收-' + [guid]::NewGuid() + '.txt')
  $p = Start-Process curl.exe -ArgumentList '--silent', '--noproxy', '*', '--max-time', '12', '--output', "`"$out`"", '--write-out', '%{http_code}', $Url -PassThru -WindowStyle Hidden -RedirectStandardOutput "$out.code"
  $hit = $null; $deadline = [DateTime]::UtcNow.AddSeconds(12)
  while (-not $hit -and [DateTime]::UtcNow -lt $deadline) {
    $hit = @((Invoke-ClashApi '/connections').connections) | Where-Object {
      [string]$_.metadata.type -match 'tun' -and ($_.metadata.host -eq $Target -or (-not $_.metadata.host -and $_.metadata.destinationIP -eq $Target))
    } | Select-Object -First 1
    if (-not $hit) { if ($p.HasExited) { break }; Start-Sleep -Milliseconds 40 }
  }
  $null = $p.WaitForExit(13000)
  $code = if (Test-Path "$out.code") { (Get-Content "$out.code" -Raw).Trim() } else { '' }
  $body = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
  Remove-Item $out, "$out.code" -ErrorAction SilentlyContinue
  [pscustomobject]@{ Target = $Target; Code = $code; Caught = [bool]$hit; Rule = $(if ($hit) { "$($hit.rule),$($hit.rulePayload)".TrimEnd(',') }); Group = $(if ($hit) { @($hit.chains)[-1] }); Body = $body }
}
function Format-Probe($r) { '{0} {1} → {2}（{3}）' -f $r.Target, $r.Code, $(if ($r.Caught) { $r.Group } else { '没抓到连接' }), $r.Rule }

try { $cfg = Invoke-ClashApi '/configs'; $rules = @((Invoke-ClashApi '/rules').rules) }
catch { Add-Result FAIL 'Clash 内核接口' ('读不到：' + $_.Exception.Message + '；Clash Verge 开着吗？'); exit 1 }

# 1. 模式、虚拟网卡、自启、IPv6、系统代理
$verge = Join-Path $deployClashDataDir 'verge.yaml'
$vergeKeys = @{}
if (Test-Path -LiteralPath $verge) { Select-String -LiteralPath $verge -Pattern '^(enable_auto_launch|enable_system_proxy):\s*(\S+)' | ForEach-Object { $vergeKeys[$_.Matches[0].Groups[1].Value] = $_.Matches[0].Groups[2].Value } }
$ok1 = $cfg.mode -eq 'rule' -and $cfg.tun.enable -and -not $cfg.ipv6 -and $vergeKeys.enable_auto_launch -eq 'true' -and $vergeKeys.enable_system_proxy -ne 'true'
Add-Result $(if ($ok1) { 'PASS' } else { 'FAIL' }) '1 规则模式、虚拟网卡、开机自启、IPv6 关、系统代理关' ('模式={0}；TUN={1}；IPv6={2}；开机自启={3}；系统代理={4}' -f $cfg.mode, $cfg.tun.enable, $cfg.ipv6, $vergeKeys.enable_auto_launch, $vergeKeys.enable_system_proxy)

# 2. 兜底、直连范围、出口组和全局组里没有 DIRECT、hosts 干净
$allowedDirect = '^(IPCIDR,(127\.0\.0\.0/8|10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|100\.64\.0\.0/10|169\.254\.0\.0/16|::1/128|fc00::/7|fe80::/10)|GeoSite,(bilibili|tencent)|DomainKeyword,mirrorakam|RuleSet,loyalsoldier-(direct|cncidr))$'
$directRules = @($rules | Where-Object proxy -eq 'DIRECT' | ForEach-Object { "$($_.type),$($_.payload)" })
$extraDirect = @($directRules | Where-Object { $_ -notmatch $allowedDirect })
$last = $rules[-1]
$grp = Invoke-ClashApi "/proxies/$group"
$glb = Invoke-ClashApi '/proxies/GLOBAL'
$hosts = Get-Content -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^\s*#' -and $_ -match 'claude|anthropic' }
$ok2 = $last.type -eq 'Match' -and $last.proxy -eq $group -and -not $extraDirect -and -not (@($grp.all) -contains 'DIRECT') -and (@($glb.all) -join ',') -eq $group -and -not $hosts
Add-Result $(if ($ok2) { 'PASS' } else { 'FAIL' }) '2 兜底指向出口组、直连只有规定的几类、出口组和全局组没有 DIRECT、hosts 干净' ('共 {0} 条规则，最后一条 {1} → {2}；直连 {3} 条{4}；出口组 {5} 个节点、含 DIRECT={6}；全局组={7}；hosts 里 Claude 条目 {8} 条' -f $rules.Count, $last.type, $last.proxy, $directRules.Count, $(if ($extraDirect) { '，其中不该直连的：' + ($extraDirect -join '、') } else { '' }), @($grp.all).Count, (@($grp.all) -contains 'DIRECT'), (@($glb.all) -join ','), @($hosts).Count)

# 3. 国内直连
$r3 = @(Invoke-TunProbe 'www.baidu.com' 'https://www.baidu.com/'; Invoke-TunProbe 'www.bilibili.com' 'https://www.bilibili.com/')
$ok3 = -not @($r3 | Where-Object { -not ($_.Caught -and $_.Group -eq 'DIRECT' -and $_.Code -match '^[23]') })
Add-Result $(if ($ok3) { 'PASS' } else { 'FAIL' }) '3 国内网站走直连' (($r3 | ForEach-Object { Format-Probe $_ }) -join '；')

# 4. 海外全走出口组、出口 IP 只有一个、国家 US；googletagmanager 不能直连
$targets = @(@('api.ipify.org', 'https://api.ipify.org'), @('ipinfo.io', 'https://ipinfo.io/json'), @('claude.ai', 'https://claude.ai/cdn-cgi/trace'), @('statsig.anthropic.com', 'https://statsig.anthropic.com/'), @('httpbin.org', 'https://httpbin.org/ip'))
$r4 = foreach ($t in $targets) { Invoke-TunProbe $t[0] $t[1] }
$ips = @(); $countries = @()
foreach ($r in $r4) {
  switch ($r.Target) {
    'api.ipify.org' { if ($r.Body) { $ips += $r.Body.Trim() } }
    'ipinfo.io' { try { $j = $r.Body | ConvertFrom-Json; $ips += $j.ip; $countries += $j.country } catch {} }
    'claude.ai' { if ($r.Body -match '(?m)^ip=(.+)$') { $ips += $Matches[1].Trim() }; if ($r.Body -match '(?m)^loc=(.+)$') { $countries += $Matches[1].Trim() } }
    'httpbin.org' { try { $ips += ($r.Body | ConvertFrom-Json).origin } catch {} }
  }
}
$gtm = Invoke-TunProbe 'www.googletagmanager.com' 'https://www.googletagmanager.com/'
$uniqueIps = @($ips | Where-Object { $_ } | Sort-Object -Unique).Count
$ok4 = -not @($r4 | Where-Object { -not ($_.Caught -and $_.Group -eq $group) }) -and $uniqueIps -eq 1 -and -not @($countries | Where-Object { $_ -notin $allowedCountries }) -and $countries -and $gtm.Group -ne 'DIRECT'
Add-Result $(if ($ok4) { 'PASS' } else { 'FAIL' }) ('4 海外全走出口组，出口 IP 只有一个，国家在 {0}' -f ($allowedCountries -join '/')) ((($r4 | ForEach-Object { Format-Probe $_ }) -join '；') + ('；返回 IP 的 {0} 次里不同 IP {1} 个；国家 {2}；googletagmanager → {3}' -f @($ips).Count, $uniqueIps, (($countries | Sort-Object -Unique) -join ','), $(if ($gtm.Caught) { $gtm.Group } else { '被拦截规则拦下（没有建立连接）' })))

# 5. DNS：系统解析随机子域名拿到 fake-ip
$dns = foreach ($i in 1..3) {
  $name = 'acceptance' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.github.com'
  try { @(Resolve-DnsName -Name $name -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object Type -eq 'A' | ForEach-Object IPAddress)[0] } catch { '' }
}
$ok5 = -not @($dns | Where-Object { $_ -notmatch '^198\.1[89]\.' })
Add-Result $(if ($ok5) { 'PASS' } else { 'FAIL' }) '5 系统 DNS 被代理接管（随机子域名拿到 fake-ip）' ('3 个随机子域名 → ' + (($dns | ForEach-Object { if ($_) { $_ } else { '解析失败' } }) -join '、') + '；浏览器检测页的 DNS 项由用户自己看')

# 6. 终端直连 IP 也进虚拟网卡
$r6 = Invoke-TunProbe '1.1.1.1' 'https://1.1.1.1/cdn-cgi/trace'
Add-Result $(if ($r6.Caught -and $r6.Group -eq $group) { 'PASS' } else { 'FAIL' }) '6 终端直连 IP（1.1.1.1）也走虚拟网卡进出口组' (Format-Probe $r6)

# 7、8. 断网开关装着（Windows 上是常驻过滤，重启后仍在）
$ks = & (Join-Path $root 'Desktop防护\全局断网开关.ps1') -Action Status -Json | ConvertFrom-Json
Add-Result $(if ($ks.Succeeded) { 'PASS' } else { 'FAIL' }) '7/8 全局断网开关装着' $ks.Evidence

# 9. 出口挂了必须断：设计证据
$ok9 = $grp.type -eq 'Selector' -and -not (@($grp.all) -contains 'DIRECT') -and $last.proxy -eq $group -and (@($glb.all) -join ',') -eq $group
Add-Result $(if ($ok9) { 'PASS' } else { 'FAIL' }) '9 出口挂了必须断（设计证据，未实测）' ('出口组类型 {0}（手选，不自动换节点）；含 DIRECT={1}；兜底 → {2}；全局组={3}' -f $grp.type, (@($grp.all) -contains 'DIRECT'), $last.proxy, (@($glb.all) -join ','))

Write-Host ''
Write-Host '第 10、11 项（关 TUN、退出 Clash）会断网：退出 Claude 后运行 工具\断网演练.ps1。'
$fail = @($script:results | Where-Object Status -eq 'FAIL').Count
Write-Host ('结论：{0} PASS / {1} FAIL' -f @($script:results | Where-Object Status -eq 'PASS').Count, $fail)
exit $(if ($fail) { 1 } else { 0 })
