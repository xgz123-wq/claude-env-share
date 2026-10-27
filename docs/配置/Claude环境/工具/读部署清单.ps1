# 部署清单：本机端口和路径的唯一记录（作用相当于 .env），位置 %LOCALAPPDATA%\ClaudeNetworkGuard\部署清单.json。
# 端口的源头是 Clash（混合端口在 Clash 设置里，43866 / 43867 在 Clash\Clash全局账号通道.js）；清单是一键总检从 Clash 抄下来的一份。
# 用法：脚本里点源引用本文件（按各自相对位置拼出本文件路径），再按名字取值，例如 $port = Get-DeployPort Desktop
# 清单不存在、读坏或缺某项时，用上一层 部署清单.示例.json 的默认值，并往 stderr 提示一行（有些脚本的 stdout 是 JSON，不能混进去）。
# 只读；写清单见同目录 写部署清单.ps1。

$deployManifestFile = Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard\部署清单.json'
$deployExampleFile = Join-Path (Split-Path $PSScriptRoot -Parent) '部署清单.示例.json'
$deployBrowserRoot = Join-Path $env:LOCALAPPDATA 'ClaudeAccountBrowsers'

function Read-DeployJson([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json } catch { $null }
}

function Test-DeployPortValue($Value) {
  $number = 0
  ($null -ne $Value) -and [int]::TryParse([string]$Value, [ref]$number) -and $number -ge 1 -and $number -le 65535
}

$deployManifest = Read-DeployJson $deployManifestFile
$deployDefaults = Read-DeployJson $deployExampleFile
$deployHinted = @{}

# 端口名：通用 = Clash 混合端口（Claude Code、VS Code 插件）；浏览器 = 专用 Chrome 的 SOCKS；Desktop = Claude Desktop 的 HTTP。
function Get-DeployPort {
  param([Parameter(Mandatory)][ValidateSet('通用','浏览器','Desktop')][string] $Name)
  $value = if ($deployManifest) { $deployManifest.'端口'.$Name } else { $null }
  if (Test-DeployPortValue $value) { return [int]$value }
  $fallback = if ($deployDefaults) { $deployDefaults.'端口'.$Name } else { $null }
  if (-not (Test-DeployPortValue $fallback)) { throw "部署清单和示例文件都没有有效的「端口.$Name」：$deployManifestFile；$deployExampleFile" }
  if (-not $deployHinted.ContainsKey($Name)) {
    $deployHinted[$Name] = $true
    $reason = if ($deployManifest) { "部署清单缺少有效的「端口.$Name」" } else { '没有部署清单或读不了' }
    [Console]::Error.WriteLine("提示：$reason，按默认端口 $fallback；跑一次一键总检会从 Clash 读出端口并生成清单。")
  }
  [int]$fallback
}

# 专用浏览器的认定规则只在这里写一处，一键总检和写部署清单共用：
# 当前用户桌面上，参数里含 %LOCALAPPDATA%\ClaudeAccountBrowsers\<别名>\UserData 的 .lnk。
# 环境卫士另外会把名字带 Claude、或走浏览器端口的非标准目录也列出来查，那些不进清单。
function Get-DeployBrowserShortcuts {
  $shell = New-Object -ComObject WScript.Shell
  $desktopDir = [Environment]::GetFolderPath('Desktop')
  foreach ($file in @(Get-ChildItem -LiteralPath $desktopDir -Filter '*.lnk' -File -ErrorAction SilentlyContinue)) {
    $shortcut = $shell.CreateShortcut($file.FullName)
    $arguments = [string]$shortcut.Arguments
    if (-not $arguments.Contains($deployBrowserRoot + '\')) { continue }
    $alias = if ($arguments -match [regex]::Escape($deployBrowserRoot + '\') + '([^\\"]+)\\UserData') { $Matches[1] } else { '' }
    [pscustomobject]@{
      Path      = $file.FullName
      Target    = $shortcut.TargetPath
      Arguments = $arguments
      Alias     = $alias
      UserData  = if ($alias) { Join-Path $deployBrowserRoot (Join-Path $alias 'UserData') } else { '' }
    }
  }
}
