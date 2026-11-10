$ErrorActionPreference = 'Stop'

# 端口按名字从部署清单取（通用 = Clash 混合端口，浏览器 = 专用 Chrome 的 SOCKS）；检查项名字里的 43865 / 43866 是固定字段名，不随端口变。
. (Join-Path (Split-Path $PSScriptRoot -Parent) '工具\读部署清单.ps1')
# Clash 内核接口的管道名新版 Verge 带后缀、会变，统一从公共文件取。
. (Join-Path (Split-Path $PSScriptRoot -Parent) '工具\Clash内核管道.ps1')
# 规则清单只在 Clash全局账号通道.js，这里读出来和内核实际加载的比，不另抄一份。
. (Join-Path (Split-Path $PSScriptRoot -Parent) '工具\读Claude规则.ps1')
$portCli = Get-DeployPort 通用
$portBrowser = Get-DeployPort 浏览器

$base = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$runtime = Join-Path $base 'clash-verge.yaml'
$core = 'C:\Program Files\Clash Verge\verge-mihomo.exe'
$liveScript = Join-Path $base 'profiles\Script.js'
$repoScript = Join-Path $PSScriptRoot 'Clash全局账号通道.js'

$claudeList = Get-ClaudeRuleList
$group = $claudeList.Group
$inboundPayload = ($claudeList.InboundRule -split ',')[1]

# 设计决定，不是规则清单的副本：宽泛的遥测规则不许进账号组。官方只点名一个精确的 Datadog 域名，其余留在订阅自己的分流里。
$forbiddenBroadTelemetryPayloads = @(
  'sentry.io', 'statsigapi.net', 'browser-intake-us5-datadoghq.com', 'datadog', 'sift',
  'intercom.io', 'intercomcdn.com', 'cdn.usefathom.com'
)
$forbiddenBroadTelemetryDnsDomains = @('+.sentry.io', '+.statsigapi.net', '+.datadoghq.com', '+.intercom.io', '+.intercomcdn.com')

# 连不上内核时也要照样输出 JSON，让总检显示具体原因，而不是给一个空的失败项列表。
$script:apiError = ''
function Get-ClashData([string] $Path) {
  try { Invoke-ClashApi $Path } catch {
    if (-not $script:apiError) { $script:apiError = $_.Exception.Message }
    $null
  }
}

# 只取 nameserver-policy 一段：内核接口不给 DNS 策略，只能读 Verge 生成的运行配置。
function Get-DnsPolicy([string] $Yaml) {
  $policy = @{}
  $inBlock = $false
  $indent = 0
  $key = $null
  foreach ($line in ($Yaml -split "`r?`n")) {
    if (-not $inBlock) {
      if ($line -match '^(\s*)nameserver-policy:\s*$') { $inBlock = $true; $indent = $Matches[1].Length }
      continue
    }
    if (-not $line.Trim()) { continue }
    if (($line.Length - $line.TrimStart().Length) -le $indent) { break }
    $item = $line.Trim()
    if ($item.StartsWith('- ')) {
      if ($key) { $policy[$key] = @($policy[$key]) + $item.Substring(2).Trim().Trim("'", '"') }
    } elseif ($item -match '^(.+?):\s*$') {
      $key = $Matches[1].Trim("'", '"')
      $policy[$key] = @()
    } elseif ($item -match '^(.+?):\s+(.+)$') {
      $key = $Matches[1].Trim("'", '"')
      $policy[$key] = @($Matches[2].Trim().Trim("'", '"'))
    }
  }
  $policy
}

foreach ($path in @($runtime, $core)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "缺少必需文件: $path" }
}

$text = Get-Content -LiteralPath $runtime -Raw
$listener65 = @(Get-NetTCPConnection -State Listen -LocalPort $portCli -ErrorAction SilentlyContinue)
$listener66 = @(Get-NetTCPConnection -State Listen -LocalPort $portBrowser -ErrorAction SilentlyContinue)
$account = Get-ClashData "/proxies/$group"
# 全局模式下内核只用 GLOBAL 组；JS 把它限定为只有账号组，误切全局也不会直连（2026-11-10 事故）。
$globalGroup = Get-ClashData '/proxies/GLOBAL'
$live = Get-ClashData '/configs'
$rulesResponse = Get-ClashData '/rules'
$liveRules = if ($rulesResponse) { @($rulesResponse.rules) } else { @() }
$validation = @(& $core -t -d $base -f $runtime 2>&1)
$validationExit = $LASTEXITCODE

# 取 Claude 自己的 trace，一次同时证明能到 claude.ai、拿到 Claude 看到的出口 IP。TUN 空闲后第一个 SOCKS 连接握手偏慢，单次 20 秒超时会产生假失败，故重试一次。
$socksIp = ''
$claudeStatus = '000'
for ($attempt = 1; $attempt -le 2; $attempt++) {
  $trace = (curl.exe --silent --show-error --max-time 20 --write-out 'http=%{http_code}' --socks5-hostname 127.0.0.1:$portBrowser https://claude.ai/cdn-cgi/trace 2>$null | Out-String)
  $claudeExit = $LASTEXITCODE
  if ($trace -match '(?m)^ip=(\S+)') { $socksIp = $Matches[1] }
  if ($trace -match 'http=(\d+)') { $claudeStatus = $Matches[1] }
  if ($claudeExit -eq 0 -and $claudeStatus -ne '000') { break }
  if ($attempt -eq 1) { Start-Sleep -Seconds 3 }
}
$feishuStatus = curl.exe --silent --show-error --output NUL --write-out '%{http_code}' --max-time 20 --noproxy '*' https://www.feishu.cn/
$feishuExit = $LASTEXITCODE
$proxyEnabled = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable

# 规则：和内核实际加载的比（文件改了但没重载，这里能查出来）。按 payload + 目标组比，类型名随内核版本会变。
$liveKeys = @{}
for ($i = 0; $i -lt $liveRules.Count; $i++) {
  $key = '{0}|{1}' -f $liveRules[$i].payload, $liveRules[$i].proxy
  if (-not $liveKeys.ContainsKey($key)) { $liveKeys[$key] = $i }
}
$missingClaudeRules = @($claudeList.Rules | Where-Object { -not $liveKeys.ContainsKey(('{0}|{1}' -f ($_ -split ',')[1], $group)) })
# 顺序：规则从上往下命中即停，清单里最后一条之前不许夹别的组，否则会抢走 Claude 流量。
$managedIndexes = @($claudeList.Payloads + $inboundPayload | ForEach-Object { $liveKeys["$_|$group"] } | Where-Object { $null -ne $_ })
$claudeRulesFirst = $false
if ($managedIndexes.Count -gt 0) {
  $lastManaged = ($managedIndexes | Measure-Object -Maximum).Maximum
  $claudeRulesFirst = -not @($liveRules[0..$lastManaged] | Where-Object { $_.proxy -ne $group }).Count
}
# 特征和 JS 的 isClaudeRule 同一个：只看匹配内容不看组名；组合规则（AND / OR / NOT）JS 不动，这里也不查。
$legacyClaudeBindings = @($liveRules | Where-Object {
  $_.type -notin @('AND', 'OR', 'NOT', 'Match') -and $_.payload -match $claudeList.IdentityPattern -and $_.proxy -ne $group
} | ForEach-Object { '{0},{1},{2}' -f $_.type, $_.payload, $_.proxy })
# 运行中进了账号组、但 JS 清单已经没有的：只提醒，重载 Clash 后消失。
$liveExtraRules = @($liveRules | Where-Object {
  $_.proxy -eq $group -and $_.payload -ne $inboundPayload -and $_.payload -notin $claudeList.Payloads
} | ForEach-Object { '{0},{1}' -f $_.type, $_.payload })
$broadTelemetryRulesAbsent = -not @($liveRules | Where-Object { $_.proxy -eq $group -and $_.payload -in $forbiddenBroadTelemetryPayloads }).Count

# DNS：Claude 后缀的每个解析器都要绑定账号组；只有绑定了账号组的遥测域名才算违规，订阅自己写的不管。
$dnsPolicy = Get-DnsPolicy $text
$missingClaudeDnsPolicies = @($claudeList.DnsDomains | Where-Object {
  $servers = @($dnsPolicy[$_])
  $servers.Count -eq 0 -or @($servers | Where-Object { -not $_.EndsWith("#$group") }).Count -gt 0
})
$broadTelemetryDnsPoliciesAbsent = -not @($forbiddenBroadTelemetryDnsDomains | Where-Object {
  @($dnsPolicy[$_] | Where-Object { $_ -and $_.Contains("#$group") }).Count -gt 0
}).Count
# DNS 绑定后缀只允许 ACCOUNT-US；出现其它组名即视为残留的订阅组耦合。
$foreignDnsBindingGroups = @([regex]::Matches($text, '#([\w\-\.]+)&disable-ipv6') |
  ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne $group } | Select-Object -Unique)
$liveScriptInSync = if (Test-Path -LiteralPath $liveScript) {
  (Get-FileHash -LiteralPath $liveScript).Hash -eq (Get-FileHash -LiteralPath $repoScript).Hash
} else { $false }

$checks = [ordered]@{
  MihomoApiReachable = ($null -ne $live)
  ModeIsRule = ($live.mode -eq 'rule')
  TunEnabled = [bool]$live.tun.enable
  SystemProxyDisabled = ($proxyEnabled -eq 0)
  MixedPort43865Listening = ($listener65.Count -gt 0)
  AccountPort43866Listening = ($listener66.Count -gt 0)
  SameMihomoPid = ($listener65.Count -gt 0 -and $listener66.Count -gt 0 -and $listener65[0].OwningProcess -eq $listener66[0].OwningProcess)
  AccountGroupExactlyOnce = (([regex]::Matches($text, ('(?m)^- name: ' + [regex]::Escape($group) + '$'))).Count -eq 1)
  AccountListenerExactlyOnce = (([regex]::Matches($text, ('(?m)^- name: ' + [regex]::Escape($inboundPayload) + '$'))).Count -eq 1)
  AccountRuleExactlyOnce = (@($liveRules | Where-Object { $_.payload -eq $inboundPayload -and $_.proxy -eq $group }).Count -eq 1)
  ClaudeRulesUseAccountUS = ($liveRules.Count -gt 0 -and $missingClaudeRules.Count -eq 0)
  ClaudeRulesBeforeGeneralRules = $claudeRulesFirst
  NoClaudeRulesBoundToOtherGroups = ($liveRules.Count -gt 0 -and $legacyClaudeBindings.Count -eq 0)
  NoDnsBoundToOtherGroups = ($foreignDnsBindingGroups.Count -eq 0)
  ClaudeDnsUsesAccountUS = ($missingClaudeDnsPolicies.Count -eq 0)
  NoBroadTelemetryRulesInAccountUS = $broadTelemetryRulesAbsent
  NoBroadTelemetryDnsInAccountUS = $broadTelemetryDnsPoliciesAbsent
  GlobalModeUsesAccountOnly = ($null -ne $globalGroup -and @($globalGroup.all).Count -eq 1 -and @($globalGroup.all)[0] -eq $group -and $globalGroup.now -eq $group)
  AccountNodeSelected =($null -ne $account -and -not [string]::IsNullOrWhiteSpace($account.now))
  MihomoConfigValid = ($validationExit -eq 0)
  SocksHasPublicIp = ($socksIp -match '^(\d{1,3}(\.\d{1,3}){3}|[0-9a-fA-F:]+)$')
  ClaudeReachableThroughSocks = ($claudeExit -eq 0 -and $claudeStatus -ne '000')
  FeishuReachable = ($feishuExit -eq 0 -and $feishuStatus -match '^[23]')
}
$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object Key)
$result = [pscustomobject]@{
  Success = ($failed.Count -eq 0)
  Checks = $checks
  FailedChecks = $failed
  AccountNode = $account.now
  MissingClaudeRules = $missingClaudeRules
  MissingClaudeDnsPolicies = $missingClaudeDnsPolicies
  LegacyClaudeBindings = $legacyClaudeBindings
  LiveExtraRules = $liveExtraRules
  LiveScriptInSync = $liveScriptInSync
  ExpectedRuleCount = $claudeList.Rules.Count
  SocksPublicIp = $socksIp
  ClaudeHttpStatus = $claudeStatus
  FeishuHttpStatus = $feishuStatus
  CorePid = @($listener66.OwningProcess | Select-Object -Unique)
  Validation = $validation[-1]
  MihomoPipe = $script:clashPipeNameCache
  MihomoApiError = $script:apiError
}
$result | ConvertTo-Json -Depth 6
if ($failed.Count -gt 0) { exit 1 }
