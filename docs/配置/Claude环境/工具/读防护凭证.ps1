# 点源用：一键总检和英文启动器共用的直连防护凭证判定，两边按同一套标准认「防护有效」。
# 管理员脚本 Desktop防护\应用直连防护管理.ps1 在 UAC 里跑、更新前整套备份，保留自己的一份 Test-GuardBinary 和插件判定，不点源本文件。
# 2026-11-21 起插件路径判定（Get-PluginGuardProblem）和 Desktop 代理来源（Get-DesktopProxySetting）也收到这里：之前两边各写一份，已经分叉。

# 当前活动的 VS Code Claude Code 插件是否就是防护清单里登记的那个程序。合格返回空字符串，否则返回原因。
# 要求：清单里恰好一个插件目标；extensions.json 只登记一条、pinned=true、targetPlatform=win32-x64；路径和清单一致；没配 claudeProcessWrapper。
function Get-PluginGuardProblem($ManifestTargets) {
  $pluginTargets = @($ManifestTargets | Where-Object Name -eq 'Claude Code VS Code 插件')
  if ($pluginTargets.Count -ne 1) { return "防护清单里的 VS Code 插件目标数量为 $($pluginTargets.Count)，预期 1" }
  $registry = Join-Path $env:USERPROFILE '.vscode\extensions\extensions.json'
  if (-not (Test-Path -LiteralPath $registry)) { return '缺少 VS Code extensions.json，无法确认当前插件路径' }
  $records = @((Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json) | Where-Object { $_.identifier.id -ieq 'anthropic.claude-code' })
  if ($records.Count -ne 1) { return "VS Code 当前登记的 Claude Code 插件数量为 $($records.Count)，预期 1" }
  if ($records[0].metadata.pinned -ne $true) { return 'VS Code Claude Code 插件未固定版本，自动更新可能更换未受保护的路径' }
  if ([string]$records[0].metadata.targetPlatform -ne 'win32-x64') { return "VS Code Claude Code 插件平台为 $($records[0].metadata.targetPlatform)，预期 win32-x64" }
  $root = [string]$records[0].location.path
  if ($root -match '^/([A-Za-z]:/.*)$') { $root = $Matches[1] }
  $current = Join-Path $root.Replace('/','\') 'resources\native-binary\claude.exe'
  if ($pluginTargets[0].Path -ine $current) { return "VS Code 插件路径已变化，防护要先迁移：当前=$current；防护=$($pluginTargets[0].Path)" }
  $settings = Join-Path $env:APPDATA 'Code\User\settings.json'
  if (Test-Path -LiteralPath $settings) {
    $wrapper = [regex]::Match((Get-Content -LiteralPath $settings -Raw), '"claudeCode\.claudeProcessWrapper"\s*:\s*"([^"]*)"')
    if ($wrapper.Success -and $wrapper.Groups[1].Value.Trim()) { return 'VS Code 配置了 claudeProcessWrapper，实际启动程序不再是受保护的插件 claude.exe' }
  }
  return ''
}

# Desktop 实际用的代理：HKLM 策略 → HKCU 策略 → configLibrary 里正在用的本地配置。
# 某一层有 disableAutoUpdates 或 egressProxyUrl 任一项，就算这一层有策略，本地配置被忽略，代理只看同层的 egressProxyUrl。
# 返回 Source（HKLM 策略 / HKCU 策略 / 本地配置）、Value、Problem（读不到时的原因，读到为空）。
function Get-DesktopProxySetting {
  foreach ($layer in @(@{ Source = 'HKLM 策略'; Key = 'HKLM:\SOFTWARE\Policies\Claude' }, @{ Source = 'HKCU 策略'; Key = 'HKCU:\SOFTWARE\Policies\Claude' })) {
    $policy = Get-ItemProperty -Path $layer.Key -ErrorAction SilentlyContinue
    if (($null -ne $policy.disableAutoUpdates) -or -not [string]::IsNullOrWhiteSpace([string]$policy.egressProxyUrl)) {
      return [pscustomobject]@{ Source = $layer.Source; Value = [string]$policy.egressProxyUrl; Problem = '' }
    }
  }
  $configRoot = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
  $metaPath = Join-Path $configRoot '_meta.json'
  if (-not (Test-Path -LiteralPath $metaPath)) { return [pscustomobject]@{ Source = '本地配置'; Value = ''; Problem = '没有 Claude 策略，也缺少 configLibrary 元数据' } }
  try {
    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$meta.appliedId)) { return [pscustomobject]@{ Source = '本地配置'; Value = ''; Problem = 'Claude Desktop 当前配置没有有效的 appliedId' } }
    $profilePath = Join-Path $configRoot ($meta.appliedId + '.json')
    if (-not (Test-Path -LiteralPath $profilePath)) { return [pscustomobject]@{ Source = '本地配置'; Value = ''; Problem = '找不到 Claude Desktop 当前配置文件' } }
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    return [pscustomobject]@{ Source = '本地配置'; Value = [string]$profile.egressProxyUrl; Problem = '' }
  } catch {
    return [pscustomobject]@{ Source = '本地配置'; Value = ''; Problem = '无法读取 Claude Desktop 当前应用配置' }
  }
}

# 一份记录（状态、Verify 或安装记录）里的目标和清单逐个对得上，且每个目标的两条 WFP 规则都启用、持久、精确匹配程序、只拦非回环。
# -RequireBinaryUnchanged：Verify 凭证还要求当时核验的程序文件没变。
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
