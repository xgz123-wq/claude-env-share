# Clash 内核接口（命名管道）的名字：只在这里找，其它脚本点源引用后用 (Get-ClashPipeName)，不要再写死。
# 背景：旧版 Clash Verge 固定叫 verge-mihomo；新版加了内核类型和散列后缀（例：verge-mihomo-production-<散列>），
# 而且 clash-verge.yaml 里 external-controller-pipe 写的名字不一定是正在运行的那个（2026-11-03 实测写的是 sidecar-release-…，在跑的是 production-…）。
# 所以只在系统里真实存在的 \\.\pipe\verge-mihomo* 中挑（配置值若在其中则先试），逐个用 GET /configs 返回 200 确认；枚举不到时退回配置值和旧名。
# 找到后在本脚本内缓存；找不到就抛异常并列出试过的名字。实测首次约 0.08 秒。

$script:clashPipeNameCache = $null

function Test-ClashPipe([string] $Name) {
  $pipe = $null
  try {
    $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', $Name, [System.IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(1500)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("GET /configs HTTP/1.1`r`nHost: localhost`r`nConnection: close`r`nContent-Length: 0`r`n`r`n")
    $pipe.Write($bytes, 0, $bytes.Length)
    $pipe.Flush()
    $reader = [System.IO.StreamReader]::new($pipe, [System.Text.Encoding]::ASCII, $false, 1024, $true)
    $read = $reader.ReadLineAsync()
    if (-not $read.Wait(3000)) { return $false }
    return ([string]$read.Result -match '^HTTP/1\.[01] 200')
  } catch {
    return $false
  } finally {
    if ($pipe) { $pipe.Dispose() }
  }
}

function Get-ClashPipeName {
  if ($script:clashPipeNameCache) { return $script:clashPipeNameCache }
  $configName = $null
  $configFile = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
  if (Test-Path -LiteralPath $configFile) {
    $line = Select-String -LiteralPath $configFile -Pattern '^\s*external-controller-pipe:\s*(.+?)\s*$' | Select-Object -First 1
    if ($line) { $configName = ($line.Matches[0].Groups[1].Value.Trim('''"') -replace '^\\\\\.\\pipe\\', '') }
  }
  # 只试系统里真实存在的管道：试连一个不存在的名字要等满超时（约 1.5 秒），配置值又常常不是在跑的那个。
  $existing = @(Get-ChildItem -LiteralPath '\\.\pipe\' -ErrorAction SilentlyContinue | Where-Object Name -like 'verge-mihomo*' | ForEach-Object Name | Sort-Object)
  $candidates = [System.Collections.Generic.List[string]]::new()
  if ($existing.Count) {
    if ($configName -and $existing -contains $configName) { $candidates.Add($configName) }
    foreach ($name in $existing) { if (-not $candidates.Contains($name)) { $candidates.Add($name) } }
  } else {
    # 枚举不到管道（极少见）时退回配置值和旧名。
    if ($configName) { $candidates.Add($configName) }
    if (-not $candidates.Contains('verge-mihomo')) { $candidates.Add('verge-mihomo') }
  }
  foreach ($name in $candidates) {
    if (Test-ClashPipe $name) {
      $script:clashPipeNameCache = $name
      return $name
    }
  }
  throw ('连不上 Clash 内核接口（Clash Verge 没开，或管道名又变了）；试过：' + ($candidates -join '、'))
}

# 只读调内核接口，返回解析好的 JSON。用 HTTP/1.0：内核不发 chunked，读到连接关闭就是完整响应。
# 连不上或不是 200 就抛异常，由调用方决定怎么报。
function Invoke-ClashApi {
  param([Parameter(Mandatory)] [string] $Path, [int] $TimeoutMs = 5000)
  $pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', (Get-ClashPipeName), [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
  try {
    $pipe.Connect(3000)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("GET $Path HTTP/1.0`r`nHost: localhost`r`nConnection: close`r`n`r`n")
    $pipe.Write($bytes, 0, $bytes.Length)
    $pipe.Flush()
    $buffer = [IO.MemoryStream]::new()
    if (-not $pipe.CopyToAsync($buffer).Wait($TimeoutMs)) { throw "内核接口 $Path 超过 $TimeoutMs 毫秒没读完" }
    $response = [System.Text.Encoding]::UTF8.GetString($buffer.ToArray())
    $split = $response.IndexOf("`r`n`r`n")
    if ($split -lt 0) { throw "内核接口 $Path 返回内容不完整" }
    $status = ($response.Substring(0, $split) -split "`r`n")[0]
    if ($status -notmatch ' 200 ') { throw "内核接口 $Path 返回 $status" }
    $response.Substring($split + 4) | ConvertFrom-Json
  } finally {
    $pipe.Dispose()
  }
}
