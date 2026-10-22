#requires -Version 7.0
# 三端更新编排器：一次调用走完「查版本 → Desktop 落后就下载并审核官方包 → 汇总 4 个受保护目标的指纹 → 给出一条一键更新命令」。
# -Plan 只查只下（不提权、不安装、不启动 Claude）；-Run 直接执行一键更新，全程只弹一次 UAC。
# 前置条件：没有名为 claude 的进程在跑，有则报 blocked_running 由用户退出后重跑。
# 前置条件：CLI 与插件已装到最新（本脚本只下载 Desktop、登记新指纹），仍落后就报 install_needed 并列出要先做的事，不下载。
# 安全边界：哈希与清单不同时必须带有效 Anthropic 签名才允许进入更新参数；不结束进程、不改策略、不启动 Claude。
# 只有 CLI 变了（Desktop 最新、插件没换目录）时报 up_to_date，CliSignatureAccepted 列出按签名放行的 CLI 目标。
[CmdletBinding()]
param([ValidateSet('Plan','Run')][string]$Action = 'Plan')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSStyle.OutputRendering = 'PlainText'

$result = [ordered]@{
    At = (Get-Date -Format o); Action = $Action; Status = 'running'
    RunningProcesses = @(); Products = @(); NextSteps = @(); ChangedTargets = @()
    Plan = $null; Command = $null; Maintenance = $null; Timing = [ordered]@{}; Error = $null
}

function Quote-Literal { param([string]$Value) return ("'" + $Value.Replace("'", "''") + "'") }

# 记录各阶段完成时距开始的秒数，耗时复盘直接读这里，不再估算。
$clock = [Diagnostics.Stopwatch]::StartNew()
function Mark-Time { param([string]$Name) $result.Timing[$Name] = [math]::Round($clock.Elapsed.TotalSeconds, 1) }

# 子脚本用 pwsh 7 独立进程调用：脚本内部有 exit，直接调用会提前终止本编排器。
function Invoke-ChildJson {
    param([string]$FileName, [string[]]$Arguments = @())
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        $raw = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot $FileName) @Arguments 2> $stderrPath | Out-String
        $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { throw ($FileName + ' 失败：' + ($raw + $stderr).Trim()) }
        return ($raw | ConvertFrom-Json)
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

try {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Select-Object ProcessId, ExecutablePath)
    if ($running.Count) {
        $result.RunningProcesses = $running
        $result.Status = 'blocked_running'
        $result.Error = '有 claude 进程在运行；请退出 Claude Code（含 VS Code 插件会话）与 Claude Desktop 后重跑。'
        $result | ConvertTo-Json -Depth 8
        exit 1
    }

    $versions = Invoke-ChildJson '查询Claude最新版本.ps1'
    $result.Products = @($versions.Results | ForEach-Object {
        [ordered]@{ Product = $_.Product; Installed = $_.Installed; Latest = $_.Latest; Status = $_.Status }
    })
    Mark-Time '查版本'

    # CLI、插件由 npm 和 VS Code 自己安装，本脚本只登记新指纹；它们还落后时这里只能拿到旧指纹，
    # 一键更新会拿旧指纹空转却报 passed（10-14 CLI 漏装）。所以先停下，不下载 Desktop、不生成命令。
    $pending = @($versions.Results | Where-Object { $_.Product -ne 'Claude Desktop' -and $_.Status -eq 'update_available' })
    if ($pending.Count) {
        $result.NextSteps = @($pending | ForEach-Object {
            if ($_.Product -eq 'Claude Code CLI') {
                'CLI ' + $_.Installed + ' → ' + $_.Latest + '：npm install -g @anthropic-ai/claude-code@' + $_.Latest + ' --registry https://registry.npmjs.org'
            } else {
                '插件 ' + $_.Installed + ' → ' + $_.Latest + '：在 VS Code 扩展页点更新，然后退出 VS Code'
            }
        })
        $result.Status = 'install_needed'
        $result.Error = '先完成 NextSteps 再重跑 Plan；本次没有下载、没有改任何文件。'
        $result | ConvertTo-Json -Depth 8
        exit 1
    }

    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot '应用过滤目标.json') -Raw | ConvertFrom-Json

    # Desktop：地址里的版本先判落后，再下载并经官方签名审核；审核不过就不产出参数。
    $desktopBehind = @($versions.Results | Where-Object { $_.Product -eq 'Claude Desktop' -and $_.Status -eq 'update_available' }).Count -gt 0
    $package = $null
    if ($desktopBehind) {
        $package = Invoke-ChildJson '下载ClaudeDesktop官方包.ps1'
        if ($package.Status -ne 'downloaded') { throw ('Desktop 安装包未就绪：' + $package.Status) }
        Mark-Time 'Desktop包就绪'
    }

    $hashes = @()
    $changed = @()
    $pluginIndex = -1
    for ($i = 0; $i -lt $manifest.Targets.Count; $i++) {
        if ($manifest.Targets[$i].Path -match '\\\.vscode\\extensions\\anthropic\.claude-code-') { $pluginIndex = $i; break }
    }
    $pluginNow = $versions.Results | Where-Object { $_.Product -like 'VS Code*' }
    $pluginMoved = [bool]($pluginNow -and ($pluginNow.ProtectedPathMatches -eq $false) -and $pluginIndex -ge 0)

    for ($i = 0; $i -lt $manifest.Targets.Count; $i++) {
        $target = $manifest.Targets[$i]
        # 插件已换版本目录时，旧路径通常已被 VS Code 删除；此项稍后从当前登记的新路径审核。
        if ($pluginMoved -and $i -eq $pluginIndex) { $hashes += $null; continue }
        $actual = (Get-FileHash -LiteralPath $target.Path -Algorithm SHA256).Hash
        $hashes += $actual
        if ($actual -eq $target.SHA256) { continue }
        $signature = Get-AuthenticodeSignature -LiteralPath $target.Path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O="?Anthropic, PBC"?(,|$)') {
            throw ('新文件缺少有效的 Anthropic 签名，拒绝进入更新参数：' + $target.Name)
        }
        $changed += [ordered]@{ Index = $i; Name = $target.Name; From = $target.SHA256; To = $actual }
    }

    # 插件换目录时旧路径可能已不存在，且第 4 项必须用新目录程序的指纹。
    $pluginApproved = $null
    if ($pluginMoved) {
        $newPluginPath = [string]$pluginNow.CurrentExe
        if (-not (Test-Path -LiteralPath $newPluginPath)) { throw ('插件新路径不存在：' + $newPluginPath) }
        $pluginApproved = (Get-FileHash -LiteralPath $newPluginPath -Algorithm SHA256).Hash
        if ($pluginApproved -ne [string]$pluginNow.CurrentSHA256) { throw '插件新程序与查询脚本给出的指纹不一致。' }
        $signature = Get-AuthenticodeSignature -LiteralPath $newPluginPath
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O="?Anthropic, PBC"?(,|$)') {
            throw '插件新程序缺少有效的 Anthropic 签名，拒绝进入更新参数。'
        }
        $hashes[$pluginIndex] = $pluginApproved
    }

    $result.ChangedTargets = $changed
    Mark-Time '指纹汇总'
    $result.Plan = [ordered]@{
        DesktopBehind = $desktopBehind
        PackagePath = [string]$package.PackagePath
        PackageSHA256 = [string]$package.SHA256
        DesktopTiming = if ($package) { $package.Timing } else { $null }
        PluginMoved = $pluginMoved
        OldPluginPath = [string]($manifest.Targets[$pluginIndex].Path)
        NewPluginPath = if ($pluginMoved) { [string]$pluginNow.CurrentExe } else { $null }
        PluginApprovedSHA256 = $pluginApproved
        CliApprovedSHA256 = $hashes
    }

    # 只有 CLI 自更新（路径不变、已过签名检查）时 WFP 规则仍生效，总检和启动器按签名放行，不必为它弹 UAC；
    # 新指纹留到下次 Desktop 或插件维护时随命令一起登记。
    $needsGuardUpdate = @($changed | Where-Object { $_.Name -notlike 'Claude Code npm*' }).Count -gt 0
    if (-not $desktopBehind -and -not $needsGuardUpdate -and -not $pluginMoved) {
        $result.CliSignatureAccepted = @($changed | ForEach-Object { $_.Name })
        $result.Status = 'up_to_date'
        $result | ConvertTo-Json -Depth 8
        exit 0
    }

    $command = '& ' + (Quote-Literal (Join-Path $PSScriptRoot '一键更新ClaudeDesktop.ps1')) + ' -Action Update'
    if ($desktopBehind) { $command += ' -PackagePath ' + (Quote-Literal $package.PackagePath) + ' -ApprovedSHA256 ' + (Quote-Literal $package.SHA256) }
    $command += ' -CliApprovedSHA256 ' + ((@($hashes) | ForEach-Object { Quote-Literal $_ }) -join ',')
    if ($pluginMoved) { $command += ' -PluginApprovedSHA256 ' + (Quote-Literal $pluginApproved) }
    $result.Command = $command

    if ($Action -eq 'Plan') {
        $result.Status = 'plan_ready'
        $result | ConvertTo-Json -Depth 8
        exit 0
    }

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -EncodedCommand $encoded 2>&1 | Out-String
    $result.Maintenance = $output.Trim()
    $result.Status = if ($LASTEXITCODE -eq 0) { 'passed' } else { 'failed' }
    Mark-Time '一键更新结束'
    $result | ConvertTo-Json -Depth 8
    exit $LASTEXITCODE
}
catch {
    $result.Status = 'failed'
    $result.Error = $_.Exception.Message
    $result | ConvertTo-Json -Depth 8
    exit 1
}
