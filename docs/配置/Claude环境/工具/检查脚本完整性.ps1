#requires -Version 7.0
# 只读检查 docs\配置\Claude环境\ 这一套脚本和文档有没有被改断：语法、相对路径、卫士依赖的入口、桌面图标目标、文档链接。
# 2026-10-26 整合后替代 Skill 的 Check-SuiteIntegrity.ps1；改了脚本或文档、搬了文件后跑一次，要求 0 FAIL。
# 不联网、不提权、不启动任何程序。运行：pwsh -NoProfile -File <本脚本>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$envRoot = Split-Path $PSScriptRoot -Parent
$projectRoot = Split-Path (Split-Path (Split-Path $envRoot -Parent) -Parent) -Parent
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([ValidateSet('PASS','WARN','FAIL')][string]$Status, [string]$Item, [string]$Evidence) {
  $results.Add([pscustomobject]@{ Status = $Status; Item = $Item; Evidence = $Evidence })
}
function Get-Relative([string]$Path) { [IO.Path]::GetRelativePath($projectRoot, $Path) }

$scripts = @(Get-ChildItem -LiteralPath $envRoot -Recurse -File -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\历史\\' })

# 1. 语法
$parseErrors = foreach ($s in $scripts) {
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$tokens, [ref]$errors)
  foreach ($e in $errors) { '{0}:{1} {2}' -f (Get-Relative $s.FullName), $e.Extent.StartLineNumber, $e.Message }
}
if ($parseErrors) { foreach ($p in $parseErrors) { Add-Result FAIL '脚本语法' $p } }
else { Add-Result PASS '脚本语法' "$($scripts.Count) 个脚本全部通过 AST 解析" }

# 2. 不用 Windows PowerShell 5.1 调子脚本（5.1 按 GBK 读无 BOM 中文脚本会整片报错）
$legacy = foreach ($s in $scripts) {
  if ($s.FullName -eq $PSCommandPath) { continue }
  $n = 0
  foreach ($line in [IO.File]::ReadAllLines($s.FullName)) {
    $n++
    if ($line -match 'powershell\.exe' -and $line.TrimStart() -notmatch '^(#|·)') { '{0}:{1}' -f (Get-Relative $s.FullName), $n }
  }
}
if ($legacy) { foreach ($l in $legacy) { Add-Result FAIL 'powershell.exe 调用' $l } }
else { Add-Result PASS 'powershell.exe 调用' '0 处' }

# 3. 相对路径：只认几种固定写法，只查程序文件（json 等运行时产物可能还没生成）
$patterns = @(
  @{ Regex = "Join-Path \`$PSScriptRoot '([^']+)'"; Up = 0 }
  @{ Regex = "Join-Path \(Split-Path \`$PSScriptRoot -Parent\) '([^']+)'"; Up = 1 }
  @{ Regex = "Join-Path \(Split-Path \(Split-Path \`$PSScriptRoot -Parent\) -Parent\) '([^']+)'"; Up = 2 }
  @{ Regex = "Join-Path \`$(?:projectRoot|root\.FullName) '([^']+)'"; Up = -1 }
)
$checked = 0
$broken = foreach ($s in $scripts) {
  $text = [IO.File]::ReadAllText($s.FullName)
  foreach ($p in $patterns) {
    foreach ($m in [regex]::Matches($text, $p.Regex)) {
      $leaf = $m.Groups[1].Value
      if ([IO.Path]::GetExtension($leaf) -notin @('.ps1', '.js', '.cjs', '.cs', '.ico')) { continue }
      $base = if ($p.Up -lt 0) { $projectRoot } else { $d = $s.DirectoryName; for ($i = 0; $i -lt $p.Up; $i++) { $d = Split-Path $d -Parent }; $d }
      $checked++
      if (-not (Test-Path -LiteralPath (Join-Path $base $leaf))) { '{0} → {1}' -f (Get-Relative $s.FullName), $leaf }
    }
  }
}
if ($broken) { foreach ($b in $broken) { Add-Result FAIL '相对路径' $b } }
else { Add-Result PASS '相对路径' "$checked 处引用全部存在" }

# 4. 环境卫士与桌面图标依赖的入口（改名或搬家会让卫士按钮失效）
$required = @(
  'README.md'
  'Claude环境一键总检.ps1'
  '启动Claude英文浏览器.ps1'
  'Anthropic网段直连阻断.ps1'
  'Clash\验证Clash账号专用通道.ps1'
  'Desktop防护\更新三端Claude.ps1'
  'Desktop防护\一键更新ClaudeDesktop.ps1'
  'Desktop防护\更新ClaudeDesktop.ps1'
  'Desktop防护\应用直连防护管理.ps1'
  '部署清单.示例.json'
  '工具\读部署清单.ps1'
  '工具\写部署清单.ps1'
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $envRoot $_)) })
if ($missing) { foreach ($m in $missing) { Add-Result FAIL '必需文件' "缺少 $m" } }
else { Add-Result PASS '必需文件' "卫士、桌面图标与部署清单依赖的 $($required.Count) 个文件在位" }
# 部署清单：示例文件是默认值来源，必须能读出三个端口；本机清单可以还没生成（跑一次一键总检生成），但有了就必须能读。
$portNames = @('通用', '浏览器', 'Desktop')
function Test-ManifestPorts($Json) { -not @($portNames | Where-Object { $p = $Json.'端口'.$_; -not ($p -is [long] -or $p -is [int]) -or $p -lt 1 -or $p -gt 65535 }) }
$exampleJson = try { Get-Content -LiteralPath (Join-Path $envRoot '部署清单.示例.json') -Raw | ConvertFrom-Json } catch { $null }
$localManifest = Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard\部署清单.json'
$localJson = if (Test-Path -LiteralPath $localManifest) { try { Get-Content -LiteralPath $localManifest -Raw | ConvertFrom-Json } catch { 'bad' } }
if (-not $exampleJson -or -not (Test-ManifestPorts $exampleJson)) { Add-Result FAIL '部署清单' '部署清单.示例.json 读不出三个有效端口' }
elseif ($null -eq $localJson) { Add-Result PASS '部署清单' '示例默认值有效；本机清单还没生成，跑一次一键总检生成' }
elseif ($localJson -eq 'bad' -or -not (Test-ManifestPorts $localJson)) { Add-Result FAIL '部署清单' "本机清单读不出三个有效端口：$localManifest" }
else { Add-Result PASS '部署清单' ('示例默认值有效；本机清单端口 ' + (($portNames | ForEach-Object { "$_=$($localJson.'端口'.$_)" }) -join '，')) }
# 防护状态是本机安装直连防护后生成的，分享包里没有；缺了总检和启动器会拦，这里只提醒。
$stateFiles = @('Desktop防护\应用过滤目标.json', 'Desktop防护\应用直连防护状态.json')
$missingState = @($stateFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $envRoot $_)) })
if ($missingState) { Add-Result WARN '防护状态' ('缺少 ' + ($missingState -join '、') + '；还没装直连防护时属正常') }
else { Add-Result PASS '防护状态' '防护清单与状态文件在位' }

# 5. 桌面上调 pwsh -File 的图标，目标脚本必须存在
$shell = New-Object -ComObject WScript.Shell
$scriptLinks = foreach ($lnk in Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Desktop')) -Filter '*.lnk' -File) {
  $sc = $shell.CreateShortcut($lnk.FullName)
  if ($sc.TargetPath -like '*pwsh.exe' -and $sc.Arguments -match '-File\s+"([^"]+)"') { [pscustomobject]@{ Name = $lnk.Name; Script = $Matches[1] } }
}
if (-not $scriptLinks) { Add-Result WARN '桌面图标' '桌面没有调用 pwsh 脚本的图标（分享包在别的机器上属正常）' }
foreach ($l in $scriptLinks) {
  if (Test-Path -LiteralPath $l.Script) { Add-Result PASS $l.Name (Get-Relative $l.Script) }
  else { Add-Result FAIL $l.Name "目标脚本不存在：$($l.Script)" }
}

# 6. 文档里的相对链接
$docRoots = @($envRoot, (Join-Path $projectRoot '.agents\skills\claude-safe-network'), (Join-Path $projectRoot '.agents\skills\claude-maintenance'))
$docs = @($docRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -File -Filter '*.md' } |
  Where-Object { $_.FullName -notmatch '\\(历史|抖音视频)\\' })
$agents = Join-Path $projectRoot 'AGENTS.md'
if (Test-Path -LiteralPath $agents) { $docs += Get-Item -LiteralPath $agents }
$linkCount = 0
$deadLinks = foreach ($doc in $docs) {
  foreach ($m in [regex]::Matches([IO.File]::ReadAllText($doc.FullName), '\]\(([^)\s]+)\)')) {
    $target = $m.Groups[1].Value
    if ($target -match '^(https?:|mailto:|#)') { continue }
    $target = [Uri]::UnescapeDataString(($target -split '#')[0])
    $linkCount++
    if (-not (Test-Path -LiteralPath (Join-Path $doc.DirectoryName $target))) { '{0} → {1}' -f (Get-Relative $doc.FullName), $target }
  }
}
if ($deadLinks) { foreach ($d in $deadLinks) { Add-Result FAIL '文档链接' $d } }
else { Add-Result PASS '文档链接' "$($docs.Count) 份文档、$linkCount 个相对链接全部有效" }

$color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
foreach ($r in $results) { Write-Host ('[{0,-4}] {1}' -f $r.Status, $r.Item) -ForegroundColor $color[$r.Status]; Write-Host ('       ' + $r.Evidence) }
$fail = @($results | Where-Object Status -eq 'FAIL').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
Write-Host ''
Write-Host ('结论：{0} PASS / {1} WARN / {2} FAIL' -f @($results | Where-Object Status -eq 'PASS').Count, $warn, $fail)
if ($fail) { exit 1 }
