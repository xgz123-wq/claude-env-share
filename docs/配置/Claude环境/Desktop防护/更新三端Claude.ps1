#requires -Version 7.0
# 三端更新一键入口：退出 Claude 后运行，一次做完「查三端版本 → CLI 落后就 npm 装 → Desktop 落后就下载官方包并审核
# → 登记 4 个受保护程序的指纹 → 一次 UAC 完成插件迁移、指纹刷新、Desktop 安装、管理员 Verify、总检、安装包清理」。
# -Action Check：只查版本和指纹，不下载、不提权、不改文件，Claude 开着也能跑。
# 插件落后仍要用户在 VS Code 扩展页点更新后重跑：VS Code 命令行装插件没实测过，不加没测过的分支。
# 子脚本的结果一律走文件，屏幕输出只进日志；10-22 之前把屏幕文字当 JSON 解析，curl 的一行报错就让流程假失败。
# 下载不做跨次续传：没下完的临时文件（Claude-<版本>-下载中.msix）直接删掉重下；10-20 的 416 续传分支就是为跨次续传存在的，删掉后不再有这条分支。
# 安全边界：文件指纹与清单不同时必须带有效 Anthropic 签名；不结束进程、不改策略、不启动 Claude。
[CmdletBinding()]
param(
    [ValidateSet('Update','Check')][string]$Action = 'Update',
    [string]$Proxy = 'http://127.0.0.1:43867'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSStyle.OutputRendering = 'PlainText'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$clock = [Diagnostics.Stopwatch]::StartNew()
$guardRoot = Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard'
$null = New-Item -ItemType Directory -Path $guardRoot -Force
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# Update 一次一个目录，记录和全部日志都在里面；Check 只留一个 json。
if ($Action -eq 'Update') {
    $runDir = Join-Path $guardRoot ('更新记录-' + $stamp)
    $null = New-Item -ItemType Directory -Path $runDir -Force
    $recordPath = Join-Path $runDir '记录.json'
} else {
    $runDir = $null
    $recordPath = Join-Path $guardRoot ('检查记录-' + $stamp + '.json')
}
$updater = Join-Path $PSScriptRoot '更新ClaudeDesktop.ps1'
$maintainer = Join-Path $PSScriptRoot '一键更新ClaudeDesktop.ps1'
$manifestPath = Join-Path $PSScriptRoot '应用过滤目标.json'
$cliPackage = Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\package.json'

$record = [ordered]@{
    At = (Get-Date -Format o); Action = $Action; Status = 'running'; RecordPath = $recordPath
    Products = @(); CliInstall = $null; Desktop = $null; Targets = @(); Maintenance = $null; After = $null
    Timing = [ordered]@{}; Error = $null
}

function Save-Record { $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $recordPath -Encoding utf8 }
function Say([string]$Text) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) }
function Mark-Time([string]$Name) { $record.Timing[$Name] = [math]::Round($clock.Elapsed.TotalSeconds, 1); Save-Record }
function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Test-AnthropicSigned([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O="?Anthropic, PBC"?(,|$)')
}
function Quote-Literal([string]$Value) { "'" + $Value.Replace("'", "''") + "'" }
# 子脚本用独立 pwsh 跑（脚本内部有 exit）；屏幕输出全部进日志文件，结果由调用方读子脚本写的文件。
function Invoke-Child([string]$Name, [string[]]$Arguments, [string]$LogPath) {
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive @Arguments *> $LogPath
    if ($LASTEXITCODE -ne 0) { throw ($Name + ' 失败，退出码 ' + $LASTEXITCODE + '；日志：' + $LogPath) }
}

function Get-InstalledDesktop {
    Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
    $packages = @(Get-AppxPackage -Name Claude)
    if ($packages.Count -ne 1) { throw '当前用户 Claude 安装包不唯一或不存在；首次安装不走本流程。' }
    return $packages[0]
}
function Get-DesktopLatest([string]$Arch) {
    # 固定来源：Anthropic Windows 部署说明给出的最新版跳转入口。HEAD 返回 405，只能用 GET 读 307 的 Location。
    $source = "https://claude.ai/api/desktop/win32/$Arch/msix/latest/redirect"
    $response = Invoke-WebRequest -Uri $source -Method Get -Proxy $Proxy -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 60 -ErrorAction SilentlyContinue
    if (-not $response) { throw '官方入口无响应；检查 43867 通道。' }
    $location = [string]($response.Headers['Location'] | Select-Object -First 1)
    if ($response.StatusCode -notin 301,302,303,307,308 -or -not $location) { throw ('官方入口没有返回跳转，状态码：' + $response.StatusCode) }
    $uri = [Uri]::new([Uri]$source, $location)
    if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '(^|\.)claude\.ai$') { throw ('跳转地址不在 claude.ai 的 HTTPS 下：' + $uri) }
    # 地址里是三段版本、已装包是四段，补齐第四段再比较；真正的版本以下载后包内 Manifest 为准。
    $version = [regex]::Match($uri.AbsolutePath, '/(\d+\.\d+\.\d+(\.\d+)?)/').Groups[1].Value
    if (-not $version) { throw ('跳转地址里没有版本号：' + $uri.AbsolutePath) }
    if ($version.Split('.').Count -eq 3) { $version += '.0' }
    return [pscustomobject]@{ Latest = $version; Url = $uri.AbsoluteUri }
}
function Get-CliInstalled {
    if (-not (Test-Path -LiteralPath $cliPackage)) { throw ('没有找到全局 CLI：' + $cliPackage) }
    return [string](Get-Content -LiteralPath $cliPackage -Raw | ConvertFrom-Json).version
}
function Get-CliLatest {
    $version = (& npm view '@anthropic-ai/claude-code' version --registry https://registry.npmjs.org 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^\d+\.\d+\.\d+$') { throw ('npm view 没有返回版本号：' + $version) }
    return $version
}
function Get-PluginInstalled {
    # 本机版本以 extensions.json 当前登记为准（旧版本目录可能还在磁盘上）。
    $registry = Join-Path $env:USERPROFILE '.vscode\extensions\extensions.json'
    if (-not (Test-Path -LiteralPath $registry)) { throw ('没有找到 ' + $registry) }
    $records = @((Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json) | Where-Object { $_.identifier.id -ieq 'anthropic.claude-code' })
    if ($records.Count -ne 1) { throw ('extensions.json 登记的 Claude Code 插件数量为 ' + $records.Count + '，预期 1') }
    $root = [string]$records[0].location.path
    if ($root -match '^/([A-Za-z]:/.*)$') { $root = $Matches[1] }
    return [pscustomobject]@{ Version = [string]$records[0].version; Exe = (Join-Path $root.Replace('/', '\') 'resources\native-binary\claude.exe') }
}
function Get-PluginLatest {
    $body = '{"filters":[{"criteria":[{"filterType":7,"value":"anthropic.claude-code"}]}],"flags":16}'
    $reply = Invoke-RestMethod -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' -Method Post -Body $body -ContentType 'application/json' -Headers @{ Accept = 'application/json;api-version=7.2-preview.1' } -Proxy $Proxy -TimeoutSec 60
    # 只比正式版：预发布版不会推给正式通道，算进来会误报插件落后。
    $versions = @($reply.results[0].extensions[0].versions | Where-Object { $_.targetPlatform -eq 'win32-x64' -and -not ($_.properties | Where-Object { $_.key -eq 'Microsoft.VisualStudio.Code.PreRelease' -and $_.value -eq 'true' }) } | ForEach-Object { [version]$_.version } | Sort-Object -Descending)
    if ($versions.Count -eq 0) { throw '官方市场没有返回 win32-x64 版本。' }
    return [string]$versions[0]
}
function New-Product([string]$Name, [string]$Installed, [string]$Latest) {
    [ordered]@{ Product = $Name; Installed = $Installed; Latest = $Latest; Status = $(if ([version]$Latest -gt [version]$Installed) { 'update_available' } else { 'up_to_date' }) }
}
# 4 个受保护程序逐个对清单：unchanged / changed_signed / changed_unsigned / moved（插件换目录）/ missing。
function Get-TargetStatus($Manifest, [string]$PluginExe) {
    return @(foreach ($target in $Manifest.Targets) {
        $row = [ordered]@{ Name = $target.Name; Path = $target.Path; State = $null; SHA256 = $null }
        if ($target.Path -match '\\\.vscode\\extensions\\anthropic\.claude-code-' -and $target.Path -ine $PluginExe) {
            $row.State = 'moved'; $row.NewPath = $PluginExe
        } elseif (-not (Test-Path -LiteralPath $target.Path)) {
            $row.State = 'missing'
        } else {
            $row.SHA256 = Get-Sha $target.Path
            $row.State = if ($row.SHA256 -eq $target.SHA256) { 'unchanged' } elseif (Test-AnthropicSigned $target.Path) { 'changed_signed' } else { 'changed_unsigned' }
        }
        $row
    })
}
function Get-DesktopPackage([string]$Version, [string]$Url) {
    $directory = Join-Path $guardRoot 'Desktop安装包下载'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $final = Join-Path $directory ('Claude-' + $Version + '.msix')
    $inspectPath = Join-Path $runDir '安装包审核.json'
    # 已按版本名落盘且审核通过的包直接复用，重跑不再拉 300 MB。
    if (Test-Path -LiteralPath $final) {
        try {
            Invoke-Child '安装包审核' @('-File', $updater, '-Action', 'Inspect', '-PackagePath', $final, '-ResultPath', $inspectPath) (Join-Path $runDir '安装包审核-复用.log')
            $inspection = Get-Content -LiteralPath $inspectPath -Raw | ConvertFrom-Json
            if ([version]$inspection.NewVersion -eq [version]$Version) {
                return [pscustomobject]@{ Path = $final; SHA256 = $inspection.SHA256; NewVersion = $inspection.NewVersion; Reused = $true; DownloadSeconds = 0 }
            }
        } catch { Say ('本地已有的安装包审核未通过，删除后重新下载：' + $_.Exception.Message) }
        Remove-Item -LiteralPath $final -Force
    }
    # 不做跨次续传：上次没下完的临时文件直接删掉重下；curl 自己的重试仍从已下字节继续。
    # 临时文件也必须以 .msix 结尾：审核只认 .msix，10-23 用 .downloading 结尾导致下载完整却审核失败。
    $temp = Join-Path $directory ('Claude-' + $Version + '-下载中.msix')
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    $curlLog = Join-Path $runDir '下载.log'
    Say ('下载 Claude Desktop ' + $Version + '（约 300 MB）…')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # 连续 20 秒低于 100 KiB/s 就断开重连（正常约 2 MB/s；旧门槛 1 KiB/s 判不出慢线路）。
    # curl 在后台下载、报错进日志；前台每秒按临时文件大小刷新一行进度。
    $curlArgs = @('--fail', '--location', '--silent', '--show-error', '--proxy', $Proxy,
        '--connect-timeout', '20', '--speed-limit', '102400', '--speed-time', '20',
        '--continue-at', '-', '--retry', '10', '--retry-all-errors', '--retry-delay', '2',
        '--output', ('"' + $temp + '"'), ('"' + $Url + '"'))
    $curl = Start-Process -FilePath 'curl.exe' -ArgumentList $curlArgs -NoNewWindow -PassThru -RedirectStandardError $curlLog
    $null = $curl.Handle  # 先拿住句柄，进程结束后才读得到 ExitCode
    while (-not $curl.WaitForExit(1000)) {
        $mb = if (Test-Path -LiteralPath $temp) { (Get-Item -LiteralPath $temp).Length / 1MB } else { 0 }
        $elapsed = $watch.Elapsed.TotalSeconds
        [Console]::Write(("`r  已下载 {0,4:N0} MB / 约 300 MB   平均 {1,4:N1} MB/s   已用 {2,4:N0} 秒   " -f $mb, ($mb / [math]::Max($elapsed, 1)), $elapsed))
    }
    [Console]::WriteLine()
    $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    if ($curl.ExitCode -ne 0) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw ('Desktop 安装包下载失败，curl 退出码 ' + $curl.ExitCode + '；未完成文件已删除，重跑会整包重下。日志：' + $curlLog)
    }
    Invoke-Child '安装包审核' @('-File', $updater, '-Action', 'Inspect', '-PackagePath', $temp, '-ResultPath', $inspectPath) (Join-Path $runDir '安装包审核.log')
    $inspection = Get-Content -LiteralPath $inspectPath -Raw | ConvertFrom-Json
    if ([version]$inspection.NewVersion -ne [version]$Version) { throw ('下载的包版本 ' + $inspection.NewVersion + ' 与入口给出的 ' + $Version + ' 不一致。') }
    Move-Item -LiteralPath $temp -Destination $final -Force
    if ((Get-Sha $final) -ne $inspection.SHA256) { throw '改名后安装包哈希变化。' }
    return [pscustomobject]@{ Path = $final; SHA256 = $inspection.SHA256; NewVersion = $inspection.NewVersion; Reused = $false; DownloadSeconds = $seconds }
}
function Show-Products($Rows) {
    foreach ($row in $Rows) {
        $mark = if ($row.Status -eq 'up_to_date') { '最新' } else { '落后' }
        Say ('  {0,-24} 已装 {1,-12} 最新 {2,-12} {3}' -f $row.Product, $row.Installed, $row.Latest, $mark)
    }
}

try {
    Save-Record
    Say ('查三端版本（记录：' + $recordPath + '）')
    $installed = Get-InstalledDesktop
    $arch = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        ([Runtime.InteropServices.Architecture]::X64) { 'x64' }
        ([Runtime.InteropServices.Architecture]::Arm64) { 'arm64' }
        default { throw ('不支持的系统架构：' + $_) }
    }
    if ([string]$installed.Architecture -ne $arch) { throw ('已装包架构 ' + $installed.Architecture + ' 与系统架构 ' + $arch + ' 不一致，停止。') }
    $desktopLatest = Get-DesktopLatest $arch
    $cliInstalled = Get-CliInstalled
    $cliLatest = Get-CliLatest
    $plugin = Get-PluginInstalled
    $pluginLatest = Get-PluginLatest
    $record.Products = @(
        (New-Product 'Claude Desktop' ([string]$installed.Version) $desktopLatest.Latest),
        (New-Product 'Claude Code CLI' $cliInstalled $cliLatest),
        (New-Product 'VS Code Claude Code 插件' $plugin.Version $pluginLatest)
    )
    Show-Products $record.Products
    Mark-Time '查版本'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    if ($Action -eq 'Check') {
        $record.Targets = Get-TargetStatus $manifest $plugin.Exe
        foreach ($row in $record.Targets) { Say ('  {0,-24} {1}' -f $row.Name, $row.State) }
        $record.Status = 'checked'
        Save-Record
        $behind = @($record.Products | Where-Object { $_.Status -eq 'update_available' })
        if ($behind.Count) { Say ('有 ' + $behind.Count + ' 端落后：退出 Claude 后运行本脚本（不带参数）即可更新。') } else { Say '三端都是最新。' }
        exit 0
    }

    # 以下是 Update。先把会让流程中途停下的条件都查完，再开始耗时的下载。
    $running = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Select-Object ProcessId, ExecutablePath)
    if ($running.Count) {
        $record.RunningProcesses = $running
        $record.Status = 'blocked_running'
        $record.Error = '有 claude 进程在运行；请退出 Claude Code（含 VS Code 插件会话）与 Claude Desktop 后重跑。'
        Save-Record
        Say $record.Error
        exit 1
    }
    if ($record.Products[2].Status -eq 'update_available') {
        # 插件只走 VS Code 官方入口；pinned=true 关掉了它的自动更新，所以要用户点一下。
        $record.Status = 'plugin_update_needed'
        $record.Error = '插件 ' + $plugin.Version + ' → ' + $pluginLatest + '：请在 VS Code 扩展页点「更新」，退出 VS Code，再重跑本脚本。本次没有下载、没有改任何文件。'
        Save-Record
        Say $record.Error
        exit 1
    }
    if ($record.Products[1].Status -eq 'update_available') {
        Say ('安装 CLI ' + $cliInstalled + ' → ' + $cliLatest + '（npm，约 1 分钟）…')
        $npmLog = Join-Path $runDir 'CLI安装.log'
        & npm install -g ('@anthropic-ai/claude-code@' + $cliLatest) --registry https://registry.npmjs.org *> $npmLog
        if ($LASTEXITCODE -ne 0) { throw ('npm 安装 CLI 失败，退出码 ' + $LASTEXITCODE + '；日志：' + $npmLog) }
        $cliNow = Get-CliInstalled
        if ($cliNow -ne $cliLatest) { throw ('npm 安装后 CLI 版本仍是 ' + $cliNow + '，预期 ' + $cliLatest) }
        $record.CliInstall = [ordered]@{ From = $cliInstalled; To = $cliNow; Log = $npmLog }
        $record.Products[1].Installed = $cliNow; $record.Products[1].Status = 'up_to_date'
        Mark-Time 'CLI安装'
    }

    $desktopBehind = $record.Products[0].Status -eq 'update_available'
    $package = $null
    if ($desktopBehind) {
        $package = Get-DesktopPackage $desktopLatest.Latest $desktopLatest.Url
        $record.Desktop = [ordered]@{ PackagePath = $package.Path; SHA256 = $package.SHA256; NewVersion = $package.NewVersion; Reused = $package.Reused; DownloadSeconds = $package.DownloadSeconds }
        Say ('安装包就绪：' + $package.Path + $(if ($package.Reused) { '（复用已审核的包）' } else { '（下载 ' + $package.DownloadSeconds + ' 秒）' }))
        Mark-Time 'Desktop包就绪'
    }

    # 登记指纹：文件变了必须有 Anthropic 签名；插件换目录时第 4 项用新目录程序的指纹。
    $record.Targets = Get-TargetStatus $manifest $plugin.Exe
    $hashes = @(); $pluginApproved = $null
    foreach ($row in $record.Targets) {
        switch ($row.State) {
            'missing' { throw ('受保护程序不存在：' + $row.Path) }
            'changed_unsigned' { throw ('新文件缺少有效的 Anthropic 签名，拒绝登记：' + $row.Name) }
            'moved' {
                if (-not (Test-Path -LiteralPath $row.NewPath)) { throw ('插件新路径不存在：' + $row.NewPath) }
                if (-not (Test-AnthropicSigned $row.NewPath)) { throw '插件新程序缺少有效的 Anthropic 签名，拒绝登记。' }
                $pluginApproved = Get-Sha $row.NewPath
                $row.SHA256 = $pluginApproved
                $hashes += $pluginApproved
            }
            default { $hashes += $row.SHA256 }
        }
        Say ('  {0,-24} {1}' -f $row.Name, $row.State)
    }
    Mark-Time '指纹汇总'
    # 只有 CLI 同路径自更新时规则仍生效、总检按签名放行，不必为它弹 UAC；新指纹留到下次一起登记。
    $guardChanged = @($record.Targets | Where-Object { $_.State -eq 'changed_signed' -and $_.Name -notlike 'Claude Code npm*' }).Count -gt 0
    $pluginMoved = @($record.Targets | Where-Object { $_.State -eq 'moved' }).Count -gt 0
    if (-not $desktopBehind -and -not $guardChanged -and -not $pluginMoved) {
        $record.Status = 'up_to_date'
        Save-Record
        Say '三端都是最新，防护不用动。'
        exit 0
    }

    # 一次 UAC：插件迁移 → 指纹刷新 → Desktop 安装 → 管理员 Verify → 总检 → 启动条件检查 → 安装包清理。
    $resultDirectory = Join-Path $runDir '统一维护'
    $command = '& ' + (Quote-Literal $maintainer) + ' -Action Update -ResultDirectory ' + (Quote-Literal $resultDirectory)
    if ($desktopBehind) { $command += ' -PackagePath ' + (Quote-Literal $package.Path) + ' -ApprovedSHA256 ' + (Quote-Literal $package.SHA256) }
    $command += ' -CliApprovedSHA256 ' + (@($hashes | ForEach-Object { Quote-Literal $_ }) -join ',')
    if ($pluginMoved) { $command += ' -PluginApprovedSHA256 ' + (Quote-Literal $pluginApproved) }
    $record.Command = $command
    Save-Record
    Say '开始更新：接下来会弹一次 UAC，请点「是」…'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    # 管理员进程在隐藏窗口里跑，每步开始、结束写一行 进度.log；这里每秒把新的整行转印到屏幕。
    $maintainLog = Join-Path $runDir '一键更新.log'
    $maintain = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
        -NoNewWindow -PassThru -RedirectStandardOutput $maintainLog -RedirectStandardError (Join-Path $runDir '一键更新-错误.log')
    $null = $maintain.Handle  # 先拿住句柄，进程结束后才读得到 ExitCode
    $progressPath = Join-Path $resultDirectory '进度.log'
    $shown = 0
    do {
        $exited = $maintain.WaitForExit(1000)
        $raw = try { Get-Content -LiteralPath $progressPath -Raw -Encoding utf8 -ErrorAction Stop } catch { '' }
        # 最后一段可能是没写完的半行，只转印换行符之前的完整行。
        $lines = @(([string]$raw) -split '\r?\n')
        for (; $shown -lt $lines.Count - 1; $shown++) { Say ('  UAC 内 ' + $lines[$shown]) }
    } until ($exited)
    if ($maintain.ExitCode -ne 0) { throw ('一键更新 失败，退出码 ' + $maintain.ExitCode + '；日志：' + $maintainLog) }
    $saved = Get-Content -LiteralPath (Join-Path $resultDirectory '结果.json') -Raw | ConvertFrom-Json
    if ($saved.Status -notin @('passed', 'passed_with_warnings')) { throw ('一键更新未通过：' + $saved.Error) }
    $record.Maintenance = [ordered]@{ ResultPath = (Join-Path $resultDirectory '结果.json'); Status = $saved.Status; Version = $saved.Version; HashCount = $saved.HashCount; FiltersCount = $saved.FiltersCount; StepSeconds = $saved.StepSeconds; Checks = $saved.Checks; Cleanup = $saved.Cleanup }
    Mark-Time '一键更新'

    # 回读：不能只凭 passed 判断已升级；插件路径要按刷新后的清单重新比对。
    $manifestAfter = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $pluginAfter = Get-PluginInstalled
    $record.After = [ordered]@{
        Desktop = [string](Get-InstalledDesktop).Version; Cli = Get-CliInstalled; Plugin = $pluginAfter.Version
        PluginProtected = [bool](@($manifestAfter.Targets.Path) -contains $pluginAfter.Exe)
    }
    if ($desktopBehind -and $record.After.Desktop -ne $package.NewVersion) { throw ('更新后 Desktop 版本回读为 ' + $record.After.Desktop + '，预期 ' + $package.NewVersion) }
    if (-not $record.After.PluginProtected) { throw '更新后插件路径仍不在防护清单里。' }
    $record.Status = 'passed'
    Mark-Time '完成'

    Say '================ 更新完成 ================'
    Say ('Desktop {0} → {1}；CLI {2}；插件 {3}（已在防护内）' -f $installed.Version, $record.After.Desktop, $record.After.Cli, $record.After.Plugin)
    Say ('管理员 Verify {0}/4 文件、{1}/8 规则；总检 PASS {2} / FAIL {3} / MANUAL {4}' -f $saved.HashCount, $saved.FiltersCount, $saved.Checks.PASS, $saved.Checks.FAIL, $saved.Checks.MANUAL)
    Say ('各步秒数：' + (@($saved.StepSeconds.PSObject.Properties | ForEach-Object { $_.Name + ' ' + $_.Value }) -join '，'))
    if ($saved.Cleanup) { Say ('安装包清理：删除 {0} 个、保留 {1} 个' -f @($saved.Cleanup.Removed).Count, @($saved.Cleanup.Kept).Count) }
    Say ('总耗时 {0} 秒；记录：{1}' -f $record.Timing['完成'], $recordPath)
    Say '没有启动 Claude；真实网页验收按长期项人工做。'
    exit 0
}
catch {
    $record.Status = 'failed'
    $record.Error = $_.Exception.Message
    Save-Record
    Say ('失败：' + $record.Error)
    Say ('记录：' + $recordPath + '；防护、日志和安装包都已保留，不要重复提权碰运气，把这条错误交给维护会话处理。')
    exit 1
}
