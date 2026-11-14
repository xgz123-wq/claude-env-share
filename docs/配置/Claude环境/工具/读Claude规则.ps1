# 从 Clash\Clash全局账号通道.js 读 Claude 规则清单。JS 是规则的唯一来源，验证脚本、官方域名复核、架构讲解页都调这里，不要在别处另抄一份。
# 用法：. <本脚本>；$list = Get-ClaudeRuleList
# 返回：Group、InboundRule、Suffixes / Exact / Geosites / IpRules（每条 Value + Note，Note 是 JS 行尾的用途说明）、
#       Rules（按顺序的完整规则串）、DnsDomains（+.后缀）、Payloads（规则的匹配内容，和内核 /rules 接口的 payload 对得上）、IdentityPattern。
# 只读 JS 文件本身，不连 Clash。

function Get-ClaudeRuleList {
  param([string] $ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'Clash\Clash全局账号通道.js'))

  if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "找不到规则来源：$ScriptPath" }
  $text = [IO.File]::ReadAllText($ScriptPath)

  function Read-JsString([string] $Name) {
    $m = [regex]::Match($text, 'var ' + $Name + ' = "([^"]+)";')
    if (-not $m.Success) { throw "JS 里找不到变量 $Name" }
    $m.Groups[1].Value
  }

  function Read-JsList([string] $Name) {
    $m = [regex]::Match($text, '(?ms)^\s*var ' + $Name + ' = \[\s*$(.*?)^\s*\];')
    if (-not $m.Success) { throw "JS 里找不到列表 $Name" }
    $items = foreach ($line in ($m.Groups[1].Value -split "`r?`n")) {
      if (-not $line.Trim()) { continue }
      $row = [regex]::Match($line, '^\s*"([^"]+)",?\s*(?://\s*(.*?))?\s*$')
      if (-not $row.Success) { throw "列表 $Name 里有不认识的行：$($line.Trim())" }
      [pscustomobject]@{ Value = $row.Groups[1].Value; Note = $row.Groups[2].Value }
    }
    if (-not @($items).Count) { throw "列表 $Name 是空的" }
    @($items)
  }

  $group = Read-JsString 'groupName'
  $listener = Read-JsString 'listenerName'
  $suffixes = Read-JsList 'claudeSuffixes'
  $exact = Read-JsList 'claudeExactDomains'
  $geosites = Read-JsList 'claudeGeosites'
  $ipRules = Read-JsList 'claudeIpRules'
  $identity = [regex]::Match($text, 'var claudeIdentity = /(.+)/i;')
  if (-not $identity.Success) { throw 'JS 里找不到 claudeIdentity' }

  $rules = @($suffixes | ForEach-Object { "DOMAIN-SUFFIX,$($_.Value),$group" }) +
    @($exact | ForEach-Object { "DOMAIN,$($_.Value),$group" }) +
    @($geosites | ForEach-Object { "GEOSITE,$($_.Value),$group" }) +
    @($ipRules | ForEach-Object { "$($_.Value),$group,no-resolve" })

  [pscustomobject]@{
    Group           = $group
    InboundRule     = "IN-NAME,$listener,$group"
    Suffixes        = $suffixes
    Exact           = $exact
    Geosites        = $geosites
    IpRules         = $ipRules
    Rules           = $rules
    DnsDomains      = @($suffixes | ForEach-Object { "+.$($_.Value)" })
    Payloads        = @($rules | ForEach-Object { ($_ -split ',')[1] })
    IdentityPattern = $identity.Groups[1].Value
  }
}
