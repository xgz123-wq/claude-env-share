#requires -Version 7.0
<#
只读工具：真发一次请求，看 Clash 实际用了哪条规则、进了哪个组。
用途：Clash 规则页只显示后缀（claude.ai），搜 downloads.claude.ai 搜不到；想知道某个域名或 IP 到底走哪，用它实测。
用法：pwsh -NoProfile -File <本脚本> downloads.claude.ai 153.61.224.1
      -Port 指定入口，默认部署清单的「通用」端口（只有这个入口按规则分流；另外两个入口整口进 ACCOUNT-US，不看规则）。
      -Json 输出 JSON，给总检用；不打印节点名和对端 IP。
退出码：0 全部抓到；1 有目标没抓到连接（请求太快或连不上，不等于规则有问题）。
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Mandatory, ValueFromRemainingArguments)] [string[]] $Target,
  [int] $Port,
  [switch] $Json
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path (Split-Path $PSScriptRoot -Parent) '工具\读部署清单.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) '工具\Clash内核管道.ps1')
if (-not $Port) { $Port = Get-DeployPort 通用 }

$results = foreach ($item in $Target) {
  $url = if ($item -match ':') { "https://[$item]/" } else { "https://$item/" }
  # -k：按 IP 测时证书对不上，只为建连接；不带任何账号信息。
  $curl = Start-Process curl.exe -ArgumentList '--silent', '--head', '--insecure', '--output', 'NUL', '--max-time', '10', '--proxy', "http://127.0.0.1:$Port", $url -PassThru -WindowStyle Hidden
  $hit = $null
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  while (-not $hit -and [DateTime]::UtcNow -lt $deadline) {
    $connections = @((Invoke-ClashApi '/connections').connections)
    # 同一入口的现成连接也算：它们用的是同一条规则。rule 为空的是整口进组的专用入口，这里不会命中。
    $hit = $connections | Where-Object {
      $_.rule -and [string]$_.metadata.inboundPort -eq [string]$Port -and
      ($_.metadata.host -eq $item -or (-not $_.metadata.host -and $_.metadata.destinationIP -eq $item))
    } | Select-Object -First 1
    if (-not $hit) {
      if ($curl.HasExited) { break }
      Start-Sleep -Milliseconds 40
    }
  }
  $null = $curl.WaitForExit(11000)
  [pscustomobject]@{
    Target  = $item
    Port    = $Port
    Caught  = [bool]$hit
    Rule    = if ($hit) { $hit.rule } else { '' }
    Payload = if ($hit) { $hit.rulePayload } else { '' }
    Group   = if ($hit) { @($hit.chains)[-1] } else { '' }
  }
}

if ($Json) {
  ConvertTo-Json -InputObject @($results) -Depth 3
} else {
  foreach ($r in $results) {
    if ($r.Caught) { Write-Host ('{0} → 规则 {1},{2} → 进 {3}（入口 {4}）' -f $r.Target, $r.Rule, $r.Payload, $r.Group, $r.Port) }
    else { Write-Host ('{0} → 没抓到连接（请求太快或连不上；再跑一次，或在 Clash 连接页看）' -f $r.Target) -ForegroundColor Yellow }
  }
}
if (@($results | Where-Object { -not $_.Caught }).Count) { exit 1 }
