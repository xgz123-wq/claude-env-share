# 经本机代理端口取 Claude 自己的 trace（https://claude.ai/cdn-cgi/trace），返回 Claude 眼里的出口 IP、国家和 HTTP 状态。
# 一键总检、后台出口巡检、英文启动器、通道验证共用这一份；只问 Claude 自己，不用第三方测 IP 站。
# 用法：点源本文件后 Get-ClaudeTrace -Type http|socks5h -Port <端口> [-TimeoutSeconds 12] [-Attempts 1]
# 只读：只发一个 HTTPS 请求，不改任何设置，不用管理员。
# 在 ForEach-Object -Parallel 里用：外面取 $fn = ${function:Get-ClaudeTrace}.ToString()，里面 ${function:Get-ClaudeTrace} = $using:fn。

function Get-ClaudeTrace {
  param(
    [Parameter(Mandatory)][ValidateSet('http', 'socks5h')][string] $Type,
    [Parameter(Mandatory)][int] $Port,
    [int] $TimeoutSeconds = 12,
    # 失败再试几次：TUN 空闲后第一个 SOCKS 连接握手偏慢，偶发超时
    [int] $Attempts = 1
  )
  $arguments = @('-sS', '--max-time', "$TimeoutSeconds", '--write-out', "`nhttp=%{http_code}")
  if ($Type -eq 'socks5h') { $arguments += @('--socks5-hostname', "127.0.0.1:$Port") }
  else { $arguments += @('--proxy', "http://127.0.0.1:$Port") }
  $arguments += 'https://claude.ai/cdn-cgi/trace'
  $ip = ''; $loc = ''; $http = '000'; $exitCode = -1
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $body = (& curl.exe @arguments 2>$null | Out-String)
    $exitCode = $LASTEXITCODE
    if ($body -match '(?m)^ip=(\S+)') { $ip = $Matches[1] }
    if ($body -match '(?m)^loc=(\S+)') { $loc = $Matches[1] }
    if ($body -match '(?m)^http=(\d+)') { $http = $Matches[1] }
    if ($exitCode -eq 0 -and $ip) { break }
    if ($attempt -lt $Attempts) { Start-Sleep -Seconds 3 }
  }
  [pscustomobject]@{ Succeeded = ($exitCode -eq 0 -and [bool]$ip); IP = $ip; Loc = $loc; Http = $http }
}
