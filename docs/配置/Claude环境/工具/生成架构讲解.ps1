#requires -Version 7.0
<#
把规则数据、规则表和架构图填进 说明\架构讲解.html，让入口页不再过时。
来源：规则 = Clash\Clash全局账号通道.js；网段 = Anthropic网段直连阻断.ps1；图 = assets\*.svg。
只替换页面里「生成:xxx 开始 / 结束」两个标记之间的内容，其余文字是手写的。
用法：pwsh -NoProfile -File <本脚本>          重新生成并写回
      pwsh -NoProfile -File <本脚本> -Check   只比较不写文件，返回 Fresh 和 Problems（完整性检查调用）
改完 JS、网段或 SVG 后跑一次。不联网，不碰 Clash。
#>
[CmdletBinding()]
param([switch] $Check)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$envRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot '读Claude规则.ps1')
$page = Join-Path $envRoot '说明\架构讲解.html'
$rangeScript = Join-Path $envRoot 'Anthropic网段直连阻断.ps1'

function Enc([string] $Text) { [System.Net.WebUtility]::HtmlEncode($Text) }
function Row([string] $Rule, [string] $Note) { "<tr><td><code>$(Enc $Rule)</code></td><td>$(Enc $Note)</td></tr>" }
function Group-Row([string] $Text) { "<tr class=`"grp`"><td colspan=`"2`">$(Enc $Text)</td></tr>" }

function Get-Ranges {
  $found = [regex]::Matches([IO.File]::ReadAllText($rangeScript), "RuleName = '([^']+)'; Cidr = '([^']+)'")
  if (-not $found.Count) { throw "没有在 $rangeScript 里读到网段" }
  foreach ($m in $found) { [pscustomobject]@{ Rule = $m.Groups[1].Value; Cidr = $m.Groups[2].Value } }
}

# 给页面里的查询框用：浏览器按这份数据判断一个域名或 IP 命中哪条规则。
function Get-RuleData {
  $list = Get-ClaudeRuleList
  function Items($Rows) { @($Rows | ForEach-Object { [ordered]@{ v = $_.Value; n = $_.Note } }) }
  $data = [ordered]@{
    group    = $list.Group
    suffixes = @(Items $list.Suffixes)
    exact    = @(Items $list.Exact)
    geosites = @(Items $list.Geosites)
    ip       = @(Items $list.IpRules)
    block    = @(Get-Ranges | ForEach-Object Cidr)
  }
  '<script type="application/json" id="rule-data">' + ($data | ConvertTo-Json -Depth 5 -Compress) + '</script>'
}

function Get-RuleTable {
  $list = Get-ClaudeRuleList
  $g = $list.Group
  $rows = @('<div class="tw"><table class="rules">', '<tr><th>规则（从上往下，碰到就停）</th><th>用途</th></tr>')
  $rows += Group-Row '专用 Chrome 的门'
  $rows += Row $list.InboundRule '从这扇门进来的全部进出口，不分国内外'
  $rows += Group-Row "Claude 域名后缀 $(@($list.Suffixes).Count) 个：子域名全部覆盖"
  foreach ($i in $list.Suffixes) { $rows += Row "DOMAIN-SUFFIX,$($i.Value),$g" $i.Note }
  $rows += Group-Row "精确域名 $(@($list.Exact).Count) 个：后缀和 geosite 都盖不到的"
  foreach ($i in $list.Exact) { $rows += Row "DOMAIN,$($i.Value),$g" $i.Note }
  $rows += Group-Row 'geosite 分类：第三方库，补没单列的域名'
  foreach ($i in $list.Geosites) { $rows += Row "GEOSITE,$($i.Value),$g" $i.Note }
  $rows += Group-Row "IP 规则 $(@($list.IpRules).Count) 条：只有程序直接连 IP 时才命中"
  foreach ($i in $list.IpRules) { $rows += Row "$($i.Value),$g,no-resolve" $i.Note }
  $rows += Group-Row '防火墙阻断（大门黑名单）：任何程序直连这些网段都拦'
  foreach ($r in Get-Ranges) { $rows += Row $r.Cidr $r.Rule }
  $rows += '</table></div>'
  $rows -join "`n"
}

# 换行统一成 LF：分享包在别的机器上 clone 可能换成 CRLF，不能因此判成过时。
function Get-Svg([string] $Name) {
  (Get-Content -LiteralPath (Join-Path $envRoot "assets\$Name.svg") -Raw -Encoding utf8).Trim() -replace "`r`n", "`n"
}
function Get-FigureImg([string] $Name) {
  $svg = Get-Svg $Name
  $alt = [regex]::Match($svg, 'aria-label="([^"]*)"').Groups[1].Value
  $data = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($svg))
  "<img src=`"data:image/svg+xml;base64,$data`" alt=`"$alt`">"
}

function Set-Block([string] $Html, [string] $Name, [string] $Content) {
  $start = "<!-- 生成:$Name 开始 -->"
  $end = "<!-- 生成:$Name 结束 -->"
  $from = $Html.IndexOf($start)
  $to = $Html.IndexOf($end)
  if ($from -lt 0 -or $to -lt $from) { throw "页面里缺少标记：$Name" }
  $Html.Substring(0, $from + $start.Length) + "`n" + $Content + "`n" + $Html.Substring($to)
}

$current = ([IO.File]::ReadAllText($page)) -replace "`r`n", "`n"
$new = Set-Block $current '规则数据' (Get-RuleData)
$new = Set-Block $new '规则表' (Get-RuleTable)
# 总架构图直接内嵌，页面脚本才能点选和高亮；三处关系只看不点，用图片内嵌。
$new = Set-Block $new '图:Claude三入口一出口总架构' (Get-Svg 'Claude三入口一出口总架构')
$new = Set-Block $new '图:Claude环境三处关系' (Get-FigureImg 'Claude环境三处关系')

if ($Check) {
  $fresh = ($new -ceq $current)
  return [pscustomobject]@{
    Fresh    = $fresh
    Problems = if ($fresh) { '' } else { '规则、网段或 SVG 比页面新；跑一次 工具\生成架构讲解.ps1' }
  }
}
if ($new -ceq $current) {
  Write-Host '架构讲解.html 已是最新，没有改动。'
} else {
  [IO.File]::WriteAllText($page, $new, [System.Text.UTF8Encoding]::new($false))
  Write-Host '架构讲解.html 已重新生成。'
}
