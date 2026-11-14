# 点源用：一键总检和英文启动器共用的直连防护凭证判定，两边按同一套标准认「防护有效」。
# 管理员脚本 Desktop防护\应用直连防护管理.ps1 在 UAC 里跑、更新前整套备份，保留自己的一份 Test-GuardBinary，不点源本文件。

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
