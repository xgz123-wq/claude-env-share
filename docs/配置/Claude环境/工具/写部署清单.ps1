#requires -Version 7.0
# 刷新本机部署清单 %LOCALAPPDATA%\ClaudeNetworkGuard\部署清单.json：端口从 Clash 运行配置抄，专用浏览器按桌面快捷方式登记，脚本根目录取本脚本所在项目。
# 一键总检每次跑完调用；创建账号浏览器建完调用；也可单独运行。内容没变就不写；写时先写临时文件再改名。
# 只读 Clash 运行配置里的 mixed-port 和两个 listener 端口，不输出其他内容；不改 Clash、不改 Claude 配置。
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '读部署清单.ps1')

$projectRoot = Split-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) -Parent
$clashRuntime = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'

# Clash 是端口的源头：混合端口 = 通用；account-us-socks = 浏览器；claude-desktop-http = Desktop（名字由 Clash全局账号通道.js 定义）。
$clashPorts = @{}
$portSource = '部署清单默认值'
if (Test-Path -LiteralPath $clashRuntime) {
  $runtimeText = Get-Content -LiteralPath $clashRuntime -Raw
  if ($runtimeText -match '(?m)^mixed-port:\s*(\d+)\s*$') { $clashPorts['通用'] = [int]$Matches[1] }
  foreach ($pair in @(@('浏览器','account-us-socks'), @('Desktop','claude-desktop-http'))) {
    $pattern = '(?ms)^-\s*name:\s*[''"]?' + [regex]::Escape($pair[1]) + '[''"]?\s*$(?:\r?\n\s+[^\r\n]*)*?\r?\n\s+port:\s*(\d+)\s*$'
    if ($runtimeText -match $pattern) { $clashPorts[$pair[0]] = [int]$Matches[1] }
  }
  if ($clashPorts.Count) { $portSource = 'Clash 运行配置' }
}

# Clash 读不到的端口沿用清单原值，清单也没有时用示例默认值（Get-DeployPort 会提示一行）。
$ports = [ordered]@{}
foreach ($name in @('通用','浏览器','Desktop')) {
  $ports[$name] = if ($clashPorts.ContainsKey($name)) { $clashPorts[$name] } else { Get-DeployPort $name }
}

$browsers = @(Get-DeployBrowserShortcuts | Where-Object Alias | Sort-Object Alias | ForEach-Object {
  [ordered]@{ '别名' = $_.Alias; '数据目录' = $_.UserData; '快捷方式' = $_.Path }
})

$content = [ordered]@{
  '格式版本'   = 1
  '更新时间'   = ''
  '端口'       = $ports
  '脚本根目录' = $projectRoot
  '专用浏览器' = $browsers
}

# 比较时不看更新时间，内容没变就不写，免得每次总检都改文件。
$compare = { param($Value) $copy = $Value | ConvertTo-Json -Depth 5 | ConvertFrom-Json; $copy.'更新时间' = ''; $copy | ConvertTo-Json -Depth 5 -Compress }
$changed = (-not $deployManifest) -or ((& $compare $deployManifest) -ne (& $compare ([pscustomobject]$content)))
if ($changed) {
  $content['更新时间'] = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
  $null = New-Item -ItemType Directory -Path (Split-Path -Parent $deployManifestFile) -Force
  $temp = "$deployManifestFile.tmp"
  [IO.File]::WriteAllText($temp, ($content | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temp -Destination $deployManifestFile -Force
}

[pscustomobject]@{
  Changed  = $changed
  Path     = $deployManifestFile
  Source   = $portSource
  Ports    = ($ports.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '，'
  Browsers = @($browsers | ForEach-Object { $_['别名'] }) -join '、'
}
