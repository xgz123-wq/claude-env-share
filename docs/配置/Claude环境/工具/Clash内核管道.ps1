# Clash 内核接口（命名管道）的名字：只在这里找，其它脚本点源引用后用 (Get-ClashPipeName)，不要再写死。
# 背景：旧版 Clash Verge 固定叫 verge-mihomo；新版加了内核类型和散列后缀（例：verge-mihomo-production-<散列>），
# 而且 clash-verge.yaml 里 external-controller-pipe 写的名字不一定是正在运行的那个（2026-11-03 实测写的是 sidecar-release-…，在跑的是 production-…）。
# 所以按「配置值 → 枚举 \\.\pipe\verge-mihomo* → 旧名」逐个试连，用 GET /configs 返回 200 确认；找到后缓存，找不到就抛异常并列出试过的名字。

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
  $candidates = [System.Collections.Generic.List[string]]::new()
  $configFile = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml'
  if (Test-Path -LiteralPath $configFile) {
    $line = Select-String -LiteralPath $configFile -Pattern '^\s*external-controller-pipe:\s*(.+?)\s*$' | Select-Object -First 1
    if ($line) {
      $name = ($line.Matches[0].Groups[1].Value.Trim('''"') -replace '^\\\\\.\\pipe\\', '')
      if ($name) { $candidates.Add($name) }
    }
  }
  foreach ($item in @(Get-ChildItem -LiteralPath '\\.\pipe\' -ErrorAction SilentlyContinue | Where-Object Name -like 'verge-mihomo*' | Sort-Object Name)) {
    if (-not $candidates.Contains($item.Name)) { $candidates.Add($item.Name) }
  }
  if (-not $candidates.Contains('verge-mihomo')) { $candidates.Add('verge-mihomo') }
  foreach ($name in $candidates) {
    if (Test-ClashPipe $name) {
      $script:clashPipeNameCache = $name
      return $name
    }
  }
  throw ('连不上 Clash 内核接口（Clash Verge 没开，或管道名又变了）；试过：' + ($candidates -join '、'))
}
