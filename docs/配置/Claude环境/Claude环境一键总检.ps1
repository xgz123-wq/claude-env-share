[CmdletBinding()]
param(
  [switch] $OpenBrowser,
  # Guard：只查 Desktop 策略与直连防护，供一键更新在 UAC 内复核这次动过的项；默认 All 与原来一致。
  [ValidateSet('All','Guard')][string] $Scope = 'All',
  # 环境卫士「深度总检」按钮用：结果另写一份 JSON（字段：ok、pass、warn、fail、manual、results）；不传时行为不变。
  [string] $ResultPath,
  # 日常使用的专用浏览器快捷方式，-OpenBrowser 打开它；其他专用浏览器只检查不打开。
  [string] $DailyBrowser = 'Claude-账号1-专用Chrome.lnk'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$projectRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$validator = Join-Path $projectRoot 'docs\配置\Claude环境\Clash\验证Clash账号专用通道.ps1'
$runtime = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
$desktop = [Environment]::GetFolderPath('Desktop')
$guardManifest = Join-Path $projectRoot 'docs\配置\Claude环境\Desktop防护\应用过滤目标.json'
$guardState = Join-Path $projectRoot 'docs\配置\Claude环境\Desktop防护\应用直连防护状态.json'
$guardVerify = Join-Path $projectRoot 'docs\配置\Claude环境\Desktop防护\应用直连防护-Verify.json'
$guardInstall = Join-Path $projectRoot 'docs\配置\Claude环境\Desktop防护\应用直连防护-最近操作.json'
$rangeCheck = Join-Path $PSScriptRoot 'Anthropic网段直连阻断.ps1'
$desktopConfigRoot = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
$desktopMeta = Join-Path $desktopConfigRoot '_meta.json'
$manifestWriter = Join-Path $PSScriptRoot '工具\写部署清单.ps1'

# 部署清单：先按 Clash 运行配置和桌面快捷方式刷新一次（内容没变不写），再按名字取端口；-Scope Guard 在 UAC 里跑，只读不刷新。
$manifestNote = $null
if ($Scope -eq 'All') {
  try {
    $manifestRefresh = & $manifestWriter
    if ($manifestRefresh.Changed) { $manifestNote = "部署清单已按 $($manifestRefresh.Source) 刷新：$($manifestRefresh.Ports)；专用浏览器 $($manifestRefresh.Browsers)" }
  } catch {
    $manifestNote = '部署清单刷新失败，本次按原清单或默认端口检查：' + $_.Exception.Message
  }
}
. (Join-Path $PSScriptRoot '工具\读部署清单.ps1')
$portCli = Get-DeployPort 通用
$portBrowser = Get-DeployPort 浏览器
$portDesktop = Get-DeployPort Desktop
$expectedDesktopProxy = "http://127.0.0.1:$portDesktop"
$machineClaudePolicy = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Claude' -ErrorAction SilentlyContinue
$userClaudePolicy = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Policies\Claude' -ErrorAction SilentlyContinue

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
  param(
    [ValidateSet('PASS','WARN','FAIL','MANUAL')][string] $Status,
    [string] $Item,
    [string] $Evidence
  )
  $results.Add([pscustomobject]@{Status=$Status;Item=$Item;Evidence=$Evidence})
}

function Test-ProxyExit {
  param(
    [ValidateSet('http','socks5h')][string] $Type,
    [int] $Port
  )
  $arguments = @('-sS','--max-time','12')
  if ($Type -eq 'socks5h') {
    $arguments += @('--socks5-hostname', "127.0.0.1:$Port")
  } else {
    $arguments += @('--proxy', "http://127.0.0.1:$Port")
  }
  # 取 Claude 自己的 trace，而不是第三方测 IP 站：通用入口按规则分流，只有访问 Claude 域名才走 ACCOUNT-US，测别的站测到的是兜底组（Proxy）。
  $arguments += 'https://claude.ai/cdn-cgi/trace'
  $body = (& curl.exe @arguments 2>$null | Out-String)
  $exitCode = $LASTEXITCODE
  $ip = if ($body -match '(?m)^ip=(\S+)') { $Matches[1] } else { '' }
  $loc = if ($body -match '(?m)^loc=(\S+)') { $Matches[1] } else { '' }
  [pscustomobject]@{Succeeded=($exitCode -eq 0 -and [bool]$ip);IP=$ip;Loc=$loc}
}

function Test-GuardRecord {
  param(
    $RecordedTargets,
    $ManifestTargets,
    [switch]$RequireBinaryUnchanged
  )
  if (@($RecordedTargets).Count -ne @($ManifestTargets).Count) { return $false }
  foreach ($manifestTarget in @($ManifestTargets)) {
    $recordedTarget = @($RecordedTargets | Where-Object Path -eq $manifestTarget.Path)
    if ($recordedTarget.Count -ne 1) { return $false }
    if ($RequireBinaryUnchanged -and $recordedTarget[0].BinaryUnchanged -ne $true) { return $false }
    $filters = @($recordedTarget[0].Filters)
    if ($filters.Count -ne 2) { return $false }
    $expectedKeys = @([string]$manifestTarget.V4,[string]$manifestTarget.V6)
    if (@($filters | Where-Object { [string]$_.Key -notin $expectedKeys }).Count) { return $false }
    if (@($filters | Where-Object {
      $_.Enabled -ne $true -or
      $_.Persistent -ne $true -or
      $_.ExactAppIdCondition -ne $true -or
      $_.NonLoopbackCondition -ne $true -or
      $_.IsOwnedExactBlock -ne $true
    }).Count) { return $false }
  }
  return $true
}

# 返回 hash / signature / $null。CLI 会自更新且路径不变，WFP 规则仍生效，所以两个 npm 目标允许按 Anthropic 签名放行；Desktop 和插件只认登记哈希。
function Test-GuardBinary($Target) {
  if (-not (Test-Path -LiteralPath $Target.Path)) { return $null }
  if ((Get-FileHash -LiteralPath $Target.Path -Algorithm SHA256).Hash -eq $Target.SHA256) { return 'hash' }
  if ([string]$Target.Name -notlike 'Claude Code npm*') { return $null }
  $signature = Get-AuthenticodeSignature -LiteralPath $Target.Path
  if ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O="?Anthropic, PBC"?(,|$)') { return 'signature' }
  return $null
}

Write-Host ''
Write-Host 'Claude / Clash 环境一键总检' -ForegroundColor Cyan
Write-Host ('检查时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Write-Host '本工具只做检查（顺带按 Clash 刷新部署清单）；不改 Clash、不启动 Claude Code 或 Claude Desktop。' -ForegroundColor DarkGray
if ($Scope -eq 'Guard') { Write-Host '范围：只查 Desktop 策略与直连防护（更新后由一键更新调用）；Clash、出口、快捷方式、网段阻断这次不查。' -ForegroundColor DarkGray }
if ($manifestNote) { Write-Host $manifestNote -ForegroundColor DarkGray }

# Clash 规则、DNS、三个出口、专用浏览器快捷方式和更新无关，-Scope Guard 时不查。
if ($Scope -eq 'All') {
  if (-not (Test-Path -LiteralPath $validator)) {
    Add-Result FAIL '基础验证程序' "缺少文件：$validator"
  } else {
    $engine = (Get-Process -Id $PID).Path
    $output = @(& $engine -NoProfile -ExecutionPolicy Bypass -File $validator 2>&1)
    $raw = $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | Out-String
    $stderrLine = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Select-Object -First 1
    try {
      # 验证脚本中途抛异常、没有输出时，ConvertFrom-Json 拿到空串会返回空结果而不报错；不能当成通过，也不能给空的失败项列表。
      $baseResult = if ($raw.Trim()) { $raw | ConvertFrom-Json } else { $null }
      if (-not $baseResult) {
        $reason = if ($stderrLine) { 'stderr：' + [string]$stderrLine } else { '没有任何输出' }
        Add-Result FAIL '基础验证程序' ('没有拿到验证结果；' + $reason)
      } elseif ($baseResult.Success) {
        $baseCount = @($baseResult.Checks.PSObject.Properties).Count
        Add-Result PASS 'Rule / TUN / Claude 规则' "基础验证 $baseCount/$baseCount；Clash 配置语法通过"
        Add-Result PASS '国内连通' "飞书 HTTP $($baseResult.FeishuHttpStatus)"
        Add-Result PASS 'ACCOUNT-US' "当前节点：$($baseResult.AccountNode)；$portBrowser 出口：$($baseResult.SocksPublicIp)"
        # 改了 JS 没重载、现场脚本没更新，都不影响现在的分流，所以只提醒。
        $syncNotes = @()
        if (@($baseResult.LiveExtraRules).Count) { $syncNotes += "运行中还有 JS 已去掉的规则（$(@($baseResult.LiveExtraRules) -join '、')），在 Clash Verge 里重载后消失" }
        if (-not $baseResult.LiveScriptInSync) { $syncNotes += '现场 Script.js 与 Clash\Clash全局账号通道.js 不一致，重载不会带上项目里的改动' }
        if ($syncNotes.Count) { Add-Result WARN 'Clash 规则同步' ($syncNotes -join '；') }
        else { Add-Result PASS 'Clash 规则同步' "运行中的规则与 JS 清单一致（$($baseResult.ExpectedRuleCount) 条）；现场 Script.js 一致" }
      } else {
        $detail = if (@($baseResult.FailedChecks).Count) { '失败项：' + ($baseResult.FailedChecks -join ', ') } else { '验证未通过但未给出失败项' }
        if ($baseResult.MihomoApiError) { $detail += "；内核接口：$($baseResult.MihomoApiError)" }
        Add-Result FAIL 'Rule / TUN / Claude 规则' $detail
      }
    } catch {
      Add-Result FAIL '基础验证程序' ('输出不是有效 JSON' + $(if ($stderrLine) { "；stderr：$stderrLine" } else { '' }))
      $baseResult = $null
    }
  }

  if (Test-Path -LiteralPath $runtime) {
    $runtimeText = Get-Content -LiteralPath $runtime -Raw
    $strictRoute = $runtimeText -match '(?m)^\s*strict-route:\s*true\s*$'
    $dnsUdp = $runtimeText -match '(?m)^\s*-\s*any:53\s*$'
    $dnsTcp = $runtimeText -match '(?m)^\s*-\s*tcp://any:53\s*$'
    if ($strictRoute -and $dnsUdp -and $dnsTcp) {
      Add-Result PASS 'DNS 防旁路' 'strict-route=true；UDP/TCP 53 劫持已开启'
    } else {
      Add-Result FAIL 'DNS 防旁路' 'strict-route 或 UDP/TCP 53 劫持缺失'
    }
  } else {
    Add-Result FAIL 'Clash 运行配置' "缺少文件：$runtime"
  }

  $exit65 = Test-ProxyExit http $portCli
  $exit66 = Test-ProxyExit socks5h $portBrowser
  $exit67 = Test-ProxyExit http $portDesktop
  foreach ($entry in @(
    @{Name="Claude Code $portCli";Value=$exit65},
    @{Name="Claude Chrome $portBrowser";Value=$exit66},
    @{Name="Claude Desktop $portDesktop";Value=$exit67}
  )) {
    if ($entry.Value.Succeeded) {
      Add-Result PASS $entry.Name ("Claude 看到的出口：{0}（{1}）" -f $entry.Value.IP, $entry.Value.Loc)
    } else {
      Add-Result FAIL $entry.Name '经这个入口访问 claude.ai 拿不到出口 IP'
    }
  }
  $exitIps = @($exit65.IP,$exit66.IP,$exit67.IP) | Where-Object { $_ }
  if ($exitIps.Count -eq 3 -and @($exitIps | Select-Object -Unique).Count -eq 1) {
    Add-Result PASS 'Claude 三入口一致性' "三个入口均为 $($exitIps[0])"
  } else {
    Add-Result FAIL 'Claude 三入口一致性' ("$portCli/$portBrowser/$portDesktop：" + ($exitIps -join ' / '))
  }

  # 规则真正起作用的是通用入口。规则清单比对只能证明规则在，这里真发请求，看每类规则各一个域名实际进了哪个组。
  $hitTool = Join-Path $PSScriptRoot 'Clash\查域名走哪条规则.ps1'
  try {
    $engine = (Get-Process -Id $PID).Path
    $hits = @((& $engine -NoProfile -ExecutionPolicy Bypass -File $hitTool -Json 'downloads.claude.ai' 'http-intake.logs.us5.datadoghq.com' 'claude.site' 2>$null | Out-String) | ConvertFrom-Json)
    $wrongGroup = @($hits | Where-Object { $_.Caught -and $_.Group -ne 'ACCOUNT-US' })
    $notCaught = @($hits | Where-Object { -not $_.Caught })
    $hitText = (@($hits | Where-Object Caught) | ForEach-Object { '{0} → {1},{2} → {3}' -f $_.Target, $_.Rule, $_.Payload, $_.Group }) -join '；'
    if ($wrongGroup.Count) { Add-Result FAIL 'Claude 规则实际命中' $hitText }
    elseif ($notCaught.Count) { Add-Result WARN 'Claude 规则实际命中' ("没抓到连接：$(($notCaught.Target) -join '、')（请求太快或连不上，不等于规则有问题）；已抓到：$hitText") }
    else { Add-Result PASS 'Claude 规则实际命中' $hitText }
  } catch {
    Add-Result WARN 'Claude 规则实际命中' ('实测没跑成：' + $_.Exception.Message)
  }

  # Claude Code 的代理来自 settings.json。这个文件含明文 token，这里只取 env 里的几个字段，只报端口和有无。
  $claudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
  if (-not (Test-Path -LiteralPath $claudeSettings)) {
    Add-Result WARN 'Claude Code 代理设置' '没有 settings.json；Claude Code 没配代理时，直连防护会让它连不上'
  } else {
    try {
      $codeEnv = (Get-Content -LiteralPath $claudeSettings -Raw | ConvertFrom-Json).env
      $expectedCliProxy = "http://127.0.0.1:$portCli"
      $settingsFail = @()
      foreach ($name in 'HTTP_PROXY', 'HTTPS_PROXY') {
        if ($codeEnv.$name -ne $expectedCliProxy) { $settingsFail += "$name 不是 $expectedCliProxy" }
      }
      foreach ($name in 'ANTHROPIC_BASE_URL', 'ANTHROPIC_API_URL') {
        if ($codeEnv.$name) { $settingsFail += "设置了 $name，请求会发去第三方接口" }
      }
      if ($settingsFail.Count) { Add-Result FAIL 'Claude Code 代理设置' ($settingsFail -join '；') }
      elseif ([string]$codeEnv.DISABLE_AUTOUPDATER -ne '1') { Add-Result WARN 'Claude Code 代理设置' "HTTP(S)_PROXY=$portCli；但 DISABLE_AUTOUPDATER 不是 1" }
      else { Add-Result PASS 'Claude Code 代理设置' "HTTP(S)_PROXY=$portCli；没有第三方接口变量；DISABLE_AUTOUPDATER=1" }
    } catch {
      Add-Result FAIL 'Claude Code 代理设置' 'settings.json 读不出来'
    }
  }

  # 专用浏览器按 读部署清单.ps1 里的同一条规则认（桌面上 --user-data-dir 指向 ClaudeAccountBrowsers 的快捷方式），账号名从目录里取，不在脚本里写死。
  $browserEntries = @(Get-DeployBrowserShortcuts)
  $browserShortcuts = @($browserEntries | ForEach-Object Path)
  $dailyBrowserPath = Join-Path $desktop $DailyBrowser
  if ($dailyBrowserPath -notin $browserShortcuts) {
    Add-Result WARN $DailyBrowser '日常专用浏览器快捷方式不存在或没有指向 ClaudeAccountBrowsers'
  }
  $readyBrowser = $null
  foreach ($shortcut in $browserEntries) {
    $shortcutPath = $shortcut.Path
    $arguments = $shortcut.Arguments
    $expectedUserData = $shortcut.UserData
    $ready =
      ($shortcut.Target -like '*\chrome.exe') -and
      [bool]$expectedUserData -and (Test-Path -LiteralPath $expectedUserData) -and
      ($arguments.Contains('--user-data-dir="' + $expectedUserData + '"')) -and
      ($arguments.Contains("--proxy-server=`"socks5://127.0.0.1:$portBrowser`"")) -and
      ($arguments -like '*--host-resolver-rules=*') -and
      ($arguments -like '*--lang=en-US*') -and
      ($arguments -like '*disable_non_proxied_udp*')
    if ($ready) {
      Add-Result PASS ([IO.Path]::GetFileName($shortcutPath)) "独立 User Data、$portBrowser、远端 DNS、en-US、WebRTC 防旁路参数齐全"
      if ($shortcutPath -eq $dailyBrowserPath) { $readyBrowser = $shortcutPath }
    } else {
      Add-Result FAIL ([IO.Path]::GetFileName($shortcutPath)) '专用浏览器参数不完整'
    }
  }
}

if (Test-Path -LiteralPath $desktopMeta) {
  try {
    $meta = Get-Content -LiteralPath $desktopMeta -Raw | ConvertFrom-Json
    $profilePath = Join-Path $desktopConfigRoot ($meta.appliedId + '.json')
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    if ($null -ne $machineClaudePolicy.disableAutoUpdates) {
      if ($machineClaudePolicy.egressProxyUrl -eq $expectedDesktopProxy) {
        Add-Result PASS 'Claude Desktop 本地代理' "HKLM egressProxyUrl=$expectedDesktopProxy"
      } else {
        Add-Result FAIL 'Claude Desktop 本地代理' "HKLM 设置了应用行为策略，但同层缺少 $portDesktop；本地配置会被忽略"
      }
    } elseif ($null -ne $userClaudePolicy.disableAutoUpdates) {
      if ($userClaudePolicy.egressProxyUrl -eq $expectedDesktopProxy) {
        Add-Result PASS 'Claude Desktop 本地代理' "HKCU egressProxyUrl=$expectedDesktopProxy"
      } else {
        Add-Result FAIL 'Claude Desktop 本地代理' "HKCU 设置了应用行为策略，但同层缺少 $portDesktop；本地配置会被忽略"
      }
    } elseif ($profile.egressProxyUrl -eq $expectedDesktopProxy) {
      Add-Result PASS 'Claude Desktop 本地代理' "本地 egressProxyUrl=$expectedDesktopProxy"
    } else {
      Add-Result FAIL 'Claude Desktop 本地代理' "当前应用配置没有指向 $portDesktop"
    }
  } catch {
    Add-Result FAIL 'Claude Desktop 本地代理' '无法读取当前应用配置'
  }
} else {
  Add-Result FAIL 'Claude Desktop 本地代理' '缺少 configLibrary 元数据'
}

$machineUpdatePolicy = $machineClaudePolicy.disableAutoUpdates
$userUpdatePolicy = $userClaudePolicy.disableAutoUpdates
if ($null -ne $machineUpdatePolicy) {
  if ([int]$machineUpdatePolicy -eq 1 -and $machineClaudePolicy.egressProxyUrl -eq $expectedDesktopProxy) {
    Add-Result PASS 'Claude Desktop 自动更新' "HKLM 已禁更，并在同层保留 $portDesktop 代理"
  } elseif ([int]$machineUpdatePolicy -eq 1) {
    Add-Result FAIL 'Claude Desktop 自动更新' "HKLM 已禁更，但同层缺少 $portDesktop 代理，会导致网络被直连防护拒绝"
  } else {
    Add-Result WARN 'Claude Desktop 自动更新' 'HKLM 策略允许自动更新，并覆盖当前用户设置'
  }
} elseif ([int]$userUpdatePolicy -eq 1 -and $userClaudePolicy.egressProxyUrl -eq $expectedDesktopProxy) {
  Add-Result PASS 'Claude Desktop 自动更新' "HKCU 已禁更，并在同层保留 $portDesktop 代理"
} elseif ([int]$userUpdatePolicy -eq 1) {
  Add-Result FAIL 'Claude Desktop 自动更新' "HKCU 已禁更，但同层缺少 $portDesktop 代理，会导致网络被直连防护拒绝"
} else {
  Add-Result WARN 'Claude Desktop 自动更新' '未禁用；Claude Desktop 默认约每 4 小时检查更新'
}

if (Test-Path -LiteralPath $guardManifest) {
  try {
    $manifest = Get-Content -LiteralPath $guardManifest -Raw | ConvertFrom-Json
    $manifestHash = (Get-FileHash -LiteralPath $guardManifest -Algorithm SHA256).Hash
    $package = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue
    $targets = @($manifest.Targets)
    $pluginTargets = @($targets | Where-Object Name -eq 'Claude Code VS Code 插件')
    $pluginRegistry = Join-Path $env:USERPROFILE '.vscode\extensions\extensions.json'
    $currentPluginPath = $null
    $pluginPathProblem = ''
    if (-not (Test-Path -LiteralPath $pluginRegistry)) {
      $pluginPathProblem = '缺少 VS Code extensions.json，无法确认当前插件路径'
    } else {
      $pluginRecords = @((Get-Content -LiteralPath $pluginRegistry -Raw | ConvertFrom-Json) | Where-Object { $_.identifier.id -ieq 'anthropic.claude-code' })
      if ($pluginRecords.Count -ne 1) {
        $pluginPathProblem = "VS Code 当前登记的 Claude Code 插件数量为 $($pluginRecords.Count)，预期 1"
      } elseif ($pluginRecords[0].metadata.pinned -ne $true) {
        $pluginPathProblem = 'VS Code Claude Code 插件未固定版本，自动更新可能更换未受保护的路径'
      } elseif ([string]$pluginRecords[0].metadata.targetPlatform -ne 'win32-x64') {
        $pluginPathProblem = "VS Code Claude Code 插件平台为 $($pluginRecords[0].metadata.targetPlatform)，预期 win32-x64"
      } else {
        $pluginRoot = [string]$pluginRecords[0].location.path
        if ($pluginRoot -match '^/([A-Za-z]:/.*)$') { $pluginRoot = $Matches[1] }
        $pluginRoot = $pluginRoot.Replace('/','\')
        $currentPluginPath = Join-Path $pluginRoot 'resources\native-binary\claude.exe'
      }
    }
    if ($pluginTargets.Count -ne 1) {
      $pluginPathProblem = "防护清单里的 VS Code 插件目标数量为 $($pluginTargets.Count)，预期 1"
    } elseif ($currentPluginPath -and $pluginTargets[0].Path -ine $currentPluginPath) {
      $pluginPathProblem = "VS Code 插件路径已变化：当前=$currentPluginPath；防护=$($pluginTargets[0].Path)"
    }
    $vsCodeSettings = Join-Path $env:APPDATA 'Code\User\settings.json'
    if (-not $pluginPathProblem -and (Test-Path -LiteralPath $vsCodeSettings)) {
      $settingsText = Get-Content -LiteralPath $vsCodeSettings -Raw
      $wrapperMatch = [regex]::Match($settingsText, '"claudeCode\.claudeProcessWrapper"\s*:\s*"([^"]*)"')
      if ($wrapperMatch.Success -and $wrapperMatch.Groups[1].Value.Trim()) {
        $pluginPathProblem = 'VS Code 配置了 claudeProcessWrapper，实际启动程序不再是受保护的插件 claude.exe'
      }
    }
    $binaryChecks = @($targets | ForEach-Object { [pscustomobject]@{Target=$_;AcceptedBy=(Test-GuardBinary $_)} })
    $validTargets = @($binaryChecks | Where-Object AcceptedBy | ForEach-Object Target)
    $signedCli = @($binaryChecks | Where-Object AcceptedBy -eq 'signature' | ForEach-Object { $_.Target.Name })
    $state = if (Test-Path -LiteralPath $guardState) { Get-Content -LiteralPath $guardState -Raw | ConvertFrom-Json } else { $null }
    $verify = if (Test-Path -LiteralPath $guardVerify) { Get-Content -LiteralPath $guardVerify -Raw | ConvertFrom-Json } else { $null }
    $install = if (Test-Path -LiteralPath $guardInstall) { Get-Content -LiteralPath $guardInstall -Raw | ConvertFrom-Json } else { $null }
    $stateReady =
      ($null -ne $state) -and
      ([string]$state.Status -like 'installed_*') -and
      ($state.ManifestSHA256 -eq $manifestHash) -and
      (@($state.Targets).Count -eq $targets.Count)
    $verifyReady =
      ($null -ne $verify) -and
      ($verify.Status -eq 'passed') -and
      ($verify.ManifestSHA256 -eq $manifestHash) -and
      ($verify.PackageVersionMatches -eq $true) -and
      (Test-GuardRecord -RecordedTargets $verify.Targets -ManifestTargets $targets -RequireBinaryUnchanged)
    $installReady =
      ($null -ne $install) -and
      ($install.Action -eq 'Install') -and
      ($install.Status -eq 'passed') -and
      (Test-GuardRecord -RecordedTargets $install.Installed -ManifestTargets $targets)
    if ($null -eq $package) {
      Add-Result FAIL 'Claude Desktop / Code 直连防护' '未检测到已安装的 Claude Desktop 包'
    } elseif ($package.Version.ToString() -ne $manifest.PackageVersion) {
      Add-Result FAIL 'Claude Desktop / Code 直连防护' "Desktop=$($package.Version)，防护清单=$($manifest.PackageVersion)；升级后的断线防直连尚未复验"
    } elseif ($pluginPathProblem) {
      Add-Result FAIL 'Claude Desktop / Code 直连防护' $pluginPathProblem
    } elseif ($validTargets.Count -ne $targets.Count) {
      Add-Result FAIL 'Claude Desktop / Code 直连防护' ("文件基线仅 {0}/{1} 一致；需复验：{2}。英文启动器会拒绝启动，请先维护。" -f $validTargets.Count,$targets.Count,((@($targets | Where-Object { $_.Path -notin @($validTargets.Path) }) | ForEach-Object Name) -join '、'))
    } elseif (-not $stateReady) {
      Add-Result FAIL 'Claude Desktop / Code 直连防护' '当前安装状态与最新防护清单不一致'
    } elseif (-not $verifyReady -and -not $installReady) {
      Add-Result FAIL 'Claude Desktop / Code 直连防护' '缺少与当前清单一致的管理员安装或 Verify 凭证'
    } else {
      $evidenceType = if ($verifyReady) { '管理员 Verify' } else { '管理员安装记录' }
      $ruleCount = $targets.Count * 2
      $signedNote = if ($signedCli.Count) { "（其中 CLI 已自更新、按 Anthropic 签名放行：$($signedCli -join '、')）" } else { '' }
      Add-Result PASS 'Claude Desktop / Code 直连防护' "Desktop=$($package.Version)；目标文件 $($validTargets.Count)/$($targets.Count)$signedNote；$ruleCount 条精确阻断规则有$evidenceType"
      # 总检不提权，读不到 WFP 规则本身，靠的是管理员 Verify 留下的凭证；凭证太旧就提醒重做。
      if ($verifyReady -and $verify.At) {
        $verifyAge = ((Get-Date) - [datetime]$verify.At).Days
        if ($verifyAge -gt 30) { Add-Result WARN '直连防护 Verify 时效' "上次管理员 Verify 是 $verifyAge 天前（超过 30 天）；不影响规则，只是证据旧了，方便时用管理员跑一次 应用直连防护管理.ps1 -Action Verify" }
      }
    }
  } catch {
    Add-Result FAIL 'Claude Desktop / Code 直连防护' ('防护记录无法完整核验：' + $_.Exception.Message)
  }
} else {
  Add-Result FAIL 'Claude Desktop / Code 直连防护' "缺少防护清单：$guardManifest"
}

# 网段阻断和更新无关，-Scope Guard 时不查。
if ($Scope -eq 'All') {
  if (-not (Test-Path -LiteralPath $rangeCheck)) {
    Add-Result FAIL 'Anthropic 网段直连阻断' "缺少检查脚本：$rangeCheck"
  } else {
    try {
      $engine = (Get-Process -Id $PID).Path
      $rangeResult = (& $engine -NoProfile -ExecutionPolicy Bypass -File $rangeCheck -Action Check -Json 2>$null | Out-String) | ConvertFrom-Json
      if ($rangeResult.Succeeded) { Add-Result PASS 'Anthropic 网段直连阻断' $rangeResult.Evidence }
      else { Add-Result FAIL 'Anthropic 网段直连阻断' $rangeResult.Evidence }
    } catch {
      Add-Result FAIL 'Anthropic 网段直连阻断' ('检查失败：' + $_.Exception.Message)
    }
  }

  # 正在跑的 claude.exe 实际连到哪。直连防护只认精确路径，而 Desktop 自带的 Code 标签页程序路径带版本和哈希、由 Desktop 自己下载更新，进不了名单；
  # 它靠专用入口、TUN 和网段阻断兜底，所以用实际连接当证据（边界见 说明\架构讲解.html）。只读进程路径和连接。
  try {
    $registeredPaths = if (Test-Path -LiteralPath $guardManifest) { @((Get-Content -LiteralPath $guardManifest -Raw | ConvertFrom-Json).Targets.Path) } else { @() }
    $codeTabRoot = Join-Path $env:APPDATA 'Claude\claude-code\'
    $established = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object { $_.RemoteAddress -notin @('127.0.0.1', '::1') })
    $claudeProcesses = @(Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object Path | ForEach-Object {
      $processId = $_.Id
      [pscustomobject]@{
        Path     = $_.Path
        Kind     = if ($_.Path -in $registeredPaths) { '名单内' } elseif ($_.Path.StartsWith($codeTabRoot, [StringComparison]::OrdinalIgnoreCase)) { 'Code 标签页' } else { '未登记' }
        External = @($established | Where-Object OwningProcess -eq $processId).Count
      }
    })
    $listedDirect = @($claudeProcesses | Where-Object { $_.Kind -eq '名单内' -and $_.External -gt 0 })
    $otherDirect = @($claudeProcesses | Where-Object { $_.Kind -ne '名单内' -and $_.External -gt 0 })
    $unregistered = @($claudeProcesses | Where-Object Kind -eq '未登记' | ForEach-Object Path | Select-Object -Unique)
    $kindSummary = (@($claudeProcesses | Group-Object Kind) | ForEach-Object { '{0} {1}' -f $_.Name, $_.Count }) -join '，'
    if (-not $claudeProcesses.Count) { Add-Result PASS 'Claude 程序实际连接' '当前没有 Claude 程序在运行' }
    elseif ($listedDirect.Count) { Add-Result FAIL 'Claude 程序实际连接' ("名单内的程序有直连外网，直连防护可能没生效：" + (($listedDirect.Path | Select-Object -Unique) -join '、')) }
    elseif ($otherDirect.Count -or $unregistered.Count) {
      $notes = @()
      if ($otherDirect.Count) { $notes += "有直连外网：$(($otherDirect.Path | Select-Object -Unique) -join '、')" }
      if ($unregistered.Count) { $notes += "不在防护名单：$($unregistered -join '、')" }
      Add-Result WARN 'Claude 程序实际连接' ($notes -join '；')
    }
    else { Add-Result PASS 'Claude 程序实际连接' "运行中 $($claudeProcesses.Count) 个（$kindSummary）；全部只连本机代理，外连 0 条" }
  } catch {
    Add-Result WARN 'Claude 程序实际连接' ('没查成：' + $_.Exception.Message)
  }

  # hosts 里写死 Claude 域名会绕过 Clash 的 Claude 规则和 DNS 分流；环境卫士不查这一项。
  $hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  $hostsHits = @(Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue |
    Where-Object { $_ -notmatch '^\s*#' -and $_ -match '(?i)anthropic|claude|clau\.de' })
  if ($hostsHits.Count) { Add-Result FAIL 'hosts 文件' ('有 Claude 相关条目：' + ($hostsHits -join '；')) }
  else { Add-Result PASS 'hosts 文件' '没有 Claude / Anthropic 相关条目' }
}

Add-Result MANUAL '网页最终验收' '专用 Chrome / Desktop 内置浏览器分别确认：Claude IP、DNS、WebRTC、IPv6、语言和时区全绿'

# 写给环境卫士的结果文件：屏幕输出照旧，另存一份机器可读的。
if ($ResultPath) {
  $resultFail = @($results | Where-Object Status -eq 'FAIL').Count
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent ([IO.Path]::GetFullPath($ResultPath))) -Force
  [pscustomobject]@{
    script  = 'Claude环境一键总检.ps1'
    time    = (Get-Date -Format 'o')
    scope   = $Scope
    ok      = ($resultFail -eq 0)
    pass    = @($results | Where-Object Status -eq 'PASS').Count
    warn    = @($results | Where-Object Status -eq 'WARN').Count
    fail    = $resultFail
    manual  = @($results | Where-Object Status -eq 'MANUAL').Count
    results = $results
  } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}

Write-Host ''
foreach ($row in $results) {
  $color = switch ($row.Status) {
    'PASS' {'Green'}
    'WARN' {'Yellow'}
    'FAIL' {'Red'}
    default {'Cyan'}
  }
  Write-Host ('[{0,-6}] {1}' -f $row.Status,$row.Item) -ForegroundColor $color
  Write-Host ('         {0}' -f $row.Evidence)
}

$failCount = @($results | Where-Object Status -eq 'FAIL').Count
$warnCount = @($results | Where-Object Status -eq 'WARN').Count
Write-Host ''
if ($failCount -gt 0) {
  Write-Host "结论：不建议启动 Claude；存在 $failCount 个失败项、$warnCount 个提醒项。" -ForegroundColor Red
  exit 1
}
if ($warnCount -gt 0) {
  Write-Host "结论：日常运行检查通过；有 $warnCount 个防护提醒，不能把它们当成已验收。" -ForegroundColor Yellow
} else {
  Write-Host '结论：程序层检查全部通过；网页全绿后可进入日常使用。' -ForegroundColor Green
}

if ($OpenBrowser) {
  if ($null -eq $readyBrowser) {
    Write-Host ("{0} 未就绪，未启动浏览器。" -f $DailyBrowser) -ForegroundColor Red
    exit 1
  }
  Start-Process -FilePath $readyBrowser
  Write-Host ("已打开专用检测浏览器：{0}" -f ([IO.Path]::GetFileName($readyBrowser))) -ForegroundColor Cyan
}
