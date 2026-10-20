#requires -Version 7.0
# 查询或下载并审核 Claude Desktop 官方 MSIX；不提权、不安装、不启动 Claude。
# -CheckOnly：只向官方入口查最新版本号并与已装版本比较，不建目录、不下载；Status=up_to_date 或 update_available。
# 不带 -CheckOnly：已是最新时 Status=up_to_date；否则下载并审核，Status=downloaded，给出一键更新所需的 PackagePath 与 SHA256。
[CmdletBinding()]
param(
    [string]$Proxy = 'http://127.0.0.1:43867',
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSStyle.OutputRendering = 'PlainText'

# 复用底层 Inspect：签名、包家族、发布者、架构、主程序声明全部在那里审核；失败抛错并带原始输出。
function Get-Inspection {
    param([string]$Path)
    $out = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot '更新ClaudeDesktop.ps1') -Action Inspect -PackagePath $Path 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw ('安装包审核未通过：' + $out.Trim()) }
    return ($out | ConvertFrom-Json)
}

# 取远端文件大小，用于判断续传文件是否已经下满。
# 只读响应头、不传包体；失败返回 $null，调用方退化为原来的续传行为。
function Get-RemoteLength {
    param([string]$Uri, [string]$Proxy)
    $head = & curl.exe --silent --show-error --location --head --proxy $Proxy `
        --connect-timeout 20 --max-time 60 $Uri 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    # 跟随跳转后可能有多段响应头，取最后一段的 Content-Length。
    $match = @($head | Select-String -Pattern '^\s*content-length:\s*(\d+)\s*$' -CaseSensitive:$false)
    if ($match.Count -eq 0) { return $null }
    return [long]$match[-1].Matches[0].Groups[1].Value
}

$result = [ordered]@{At=(Get-Date -Format o);Status='running';OS=$null;Architecture=$null;InstalledVersion=$null;LatestVersion=$null;SourceUrl=$null;DownloadUrl=$null;PackagePath=$null;SHA256=$null;Signature=$null;NextCommand=$null;Timing=[ordered]@{};Error=$null}
try {
    if (-not $IsWindows) { throw '本流程只支持 Windows MSIX 安装；macOS 需另行编写。' }
    $result.OS = 'win32'
    # 以操作系统真实架构为准，不看 pwsh 进程架构；与已装包对不上就停止，避免跨架构替换。
    $osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $arch = switch ($osArch) {
        ([Runtime.InteropServices.Architecture]::X64) { 'x64' }
        ([Runtime.InteropServices.Architecture]::Arm64) { 'arm64' }
        default { throw ('不支持的系统架构：' + $osArch) }
    }
    $result.Architecture = $arch
    Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
    $packages = @(Get-AppxPackage -Name Claude)
    if ($packages.Count -ne 1) { throw '当前用户 Claude 安装包不唯一或不存在；首次安装不走本流程。' }
    $installed = $packages[0]
    $result.InstalledVersion = [string]$installed.Version
    if ([string]$installed.Architecture -ne $arch) { throw ('已装包架构 ' + $installed.Architecture + ' 与系统架构 ' + $arch + ' 不一致，停止。') }

    # 固定来源：Anthropic Windows 部署说明给出的最新版跳转入口。HEAD 返回 405，只能用 GET 读 307 的 Location。
    $result.SourceUrl = "https://claude.ai/api/desktop/win32/$arch/msix/latest/redirect"
    # 不跟随跳转时 pwsh 会报“超过最大跳转次数”，这里只要响应头，故压掉该错误。
    $response = Invoke-WebRequest -Uri $result.SourceUrl -Method Get -Proxy $Proxy -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 60 -ErrorAction SilentlyContinue
    if (-not $response) { throw '官方入口无响应；检查 43867 通道。' }
    $location = [string]($response.Headers['Location'] | Select-Object -First 1)
    if ($response.StatusCode -notin 301,302,303,307,308 -or -not $location) { throw ('官方入口没有返回跳转，状态码：' + $response.StatusCode) }
    $downloadUri = [Uri]::new([Uri]$result.SourceUrl, $location)
    # 2026-09-25 实测跳到 https://downloads.claude.ai/releases/win32/<架构>/<三段版本>/Claude-<提交哈希>.msix。
    if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -notmatch '(^|\.)claude\.ai$') { throw ('跳转地址不在 claude.ai 的 HTTPS 下：' + $downloadUri) }
    $result.DownloadUrl = $downloadUri.AbsoluteUri

    # 地址里的版本号只用来提前判断“已是最新”；真正的版本以下载后包内 Manifest 为准。
    # 地址是三段版本、已装包是四段，补齐第四段再比较，否则 [version] 会判为不等。
    $urlVersion = [regex]::Match($downloadUri.AbsolutePath, '/(\d+\.\d+\.\d+(\.\d+)?)/').Groups[1].Value
    if ($urlVersion -and $urlVersion.Split('.').Count -eq 3) { $urlVersion += '.0' }
    if ($urlVersion -and [version]$urlVersion -eq [version]$result.InstalledVersion) {
        $result.LatestVersion = $urlVersion
        $result.Status = 'up_to_date'
        $result | ConvertTo-Json -Depth 8
        exit 0
    }
    if ($CheckOnly) {
        if (-not $urlVersion) { throw ('跳转地址里没有版本号，无法只查不下：' + $downloadUri.AbsolutePath) }
        $result.LatestVersion = $urlVersion
        $result.Status = 'update_available'
        $result | ConvertTo-Json -Depth 8
        exit 0
    }

    $downloadDir = Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard\Desktop安装包下载'
    $null = New-Item -ItemType Directory -Path $downloadDir -Force
    # 已按版本名落盘且审核通过的包直接复用，重跑 Plan 不再重复拉 293MB。
    $final = Join-Path $downloadDir ('Claude-' + $urlVersion + '.msix')
    $inspection = $null
    if ($urlVersion -and (Test-Path -LiteralPath $final)) {
        try {
            $inspection = Get-Inspection -Path $final
            if ($inspection -and [version]$inspection.NewVersion -eq [version]$urlVersion) {
                $result.DownloadUrl = $downloadUri.AbsoluteUri + '（本地已有审核通过的包，未重新下载）'
            } else {
                $inspection = $null
            }
        } catch { $inspection = $null }
    }
    if (-not $inspection) {
        if (-not $urlVersion) { throw ('跳转地址里没有版本号，无法命名续传文件：' + $downloadUri.AbsolutePath) }
        # 固定临时名支持失败后断点续传；只有完整包审核通过后才改成 Claude-<版本>.msix。
        $partial = Join-Path $downloadDir ('Claude-' + $urlVersion + '.partial.msix')
        $needDownload = $true
        $remoteLength = $null
        # 上次下载可能已经下满、只是没来得及改名就中断；此时再续传必然被服务端回 416。
        # 所以续传前先比对远端大小：相等就直接进审核，变大就删掉重下。
        if (Test-Path -LiteralPath $partial) {
            $localLength = (Get-Item -LiteralPath $partial).Length
            $remoteLength = Get-RemoteLength -Uri $downloadUri.AbsoluteUri -Proxy $Proxy
            if ($remoteLength) {
                if ($localLength -eq $remoteLength) {
                    $needDownload = $false
                    $result.Timing.ResumeSkipped = "续传文件已与远端等长（$localLength 字节），跳过下载直接审核"
                } elseif ($localLength -gt $remoteLength) {
                    Remove-Item -LiteralPath $partial -Force
                    $result.Timing.PartialReset = "续传文件 $localLength 字节大于远端 $remoteLength 字节，已删除重下"
                }
            }
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        if ($needDownload) {
            # Invoke-WebRequest 的 TimeoutSec 是总超时，服务端未开始传输时会让 0 字节文件空等 30 分钟。
            # curl 断线后重试并从已有字节继续；连续 20 秒低于 100 KiB/s 就断开重连（正常约 2 MB/s）。
            # 旧门槛 1 KiB/s 判不出慢线路：10-14 前 2.5 分钟只有约 86 KB/s 却一直重连不上。
            & curl.exe --fail --location --silent --show-error --proxy $Proxy `
                --connect-timeout 20 --speed-limit 102400 --speed-time 20 `
                --continue-at - --retry 10 --retry-all-errors --retry-delay 2 `
                --output $partial $downloadUri.AbsoluteUri
            $curlExit = $LASTEXITCODE
        } else { $curlExit = 0 }
        $result.Timing.DownloadSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        if ($curlExit -ne 0) {
            # 416 与其它错误都可能出现在“文件其实已完整”的情况下：按远端大小复核一次，完整就继续审核，不再报失败。
            $nowLength = if (Test-Path -LiteralPath $partial) { (Get-Item -LiteralPath $partial).Length } else { 0 }
            if (-not $remoteLength) { $remoteLength = Get-RemoteLength -Uri $downloadUri.AbsoluteUri -Proxy $Proxy }
            if ($remoteLength -and $nowLength -eq $remoteLength) {
                $result.Timing.DownloadRecovered = "curl 退出码 $curlExit，但本地文件已与远端等长（$nowLength 字节），按完整包继续审核"
            } else {
                $remoteText = if ($remoteLength) { "$remoteLength 字节" } else { '未知' }
                throw ('Desktop 安装包下载失败，curl 退出码：' + $curlExit + "；本地 $nowLength 字节 / 远端 $remoteText 字节。已下部分保留，重跑会续传。")
            }
        }
        $watch.Restart()
        $inspection = Get-Inspection -Path $partial
        $result.Timing.InspectSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
        $final = Join-Path $downloadDir ('Claude-' + $inspection.NewVersion + '.msix')
        Move-Item -LiteralPath $partial -Destination $final -Force
        if ((Get-FileHash -LiteralPath $final).Hash -ne $inspection.SHA256) { throw '改名后安装包哈希变化。' }
    }
    $result.LatestVersion = $inspection.NewVersion
    $result.PackagePath = $final
    $result.SHA256 = $inspection.SHA256
    $result.Signature = $inspection.Signature
    $result.Status = if ([version]$inspection.NewVersion -eq [version]$result.InstalledVersion) { 'up_to_date' } else { 'downloaded' }
    $result.NextCommand = "一键更新ClaudeDesktop.ps1 -Action Update -PackagePath '$final' -ApprovedSHA256 '$($inspection.SHA256)'（CLI 同时更新时再加 -CliApprovedSHA256）"
    $result | ConvertTo-Json -Depth 8
} catch {
    $result.Status = 'failed'
    $result.Error = $_.Exception.Message
    $result | ConvertTo-Json -Depth 8
    exit 1
}
