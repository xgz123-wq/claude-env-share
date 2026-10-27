#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Verify','Update')][string]$Action = 'Verify',
    [string]$PackagePath,
    [string]$ApprovedSHA256,
    # CLI 或插件同路径更新后按清单顺序传入四个已审核指纹；与 Desktop 更新共用同一次 UAC，先刷新再迁移。
    [string[]]$CliApprovedSHA256,
    # VS Code 插件升级换了版本目录时传入新插件 claude.exe 的已审核指纹；先迁移插件，再刷新 CLI，最后迁移 Desktop。
    [string]$PluginApprovedSHA256,
    [string]$ResumeJournal,
    [switch]$Worker,
    [string]$ResultDirectory,
    [string]$ExpectedUserSid,
    # 日常总检只查这次更新动过的项（Desktop 策略与直连防护，总检 -Scope Guard）；不传时照旧全量总检。由环境卫士经 更新三端Claude.ps1 传入。
    [switch]$ChangedOnly
)
$ErrorActionPreference = 'Stop'
$PSStyle.OutputRendering = 'PlainText'
# Desktop 专用端口按名字从部署清单取（源头是 Clash全局账号通道.js 的 claude-desktop-http）；UAC 内同一账户，读的是同一份清单。
. (Join-Path (Split-Path $PSScriptRoot -Parent) '工具\读部署清单.ps1')
$desktopPort = Get-DeployPort Desktop
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$result = [ordered]@{At=(Get-Date -Format o);Action=$Action;Status='running';Version=$null;HashCount=0;FiltersCount=0;Disabled=$null;Proxy=$null;UACWorker=[bool]$Worker;ApplicationsLaunched=$false;Logs=@();StepSeconds=[ordered]@{};Checks=$null;Error=$null}
function Save-Result {
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding utf8
}
function Assert-Closed {
    if (@(Get-Process -Name claude -ErrorAction SilentlyContinue).Count) { throw 'Claude 正在运行；请退出后再执行。本入口不会强行关闭或启动应用。' }
}
function Quote-Literal([string]$Value) {
    if ($Value -match '[\r\n\x00]') { throw '参数不能包含换行或空字符。' }
    "'" + $Value.Replace("'", "''") + "'"
}
# 管理员进程跑在隐藏窗口里；每步开始、结束往 进度.log 追加一行，由 更新三端Claude.ps1 转印到屏幕。写失败不影响维护。
function Write-StepProgress([string]$Text) {
    try { Add-Content -LiteralPath (Join-Path $ResultDirectory '进度.log') -Value $Text -Encoding utf8 } catch { }
}
function Run-Step([string]$Name, [string]$Script, [string[]]$Arguments, [switch]$AllowFailure) {
    $log = Join-Path $ResultDirectory ($Name + '.log')
    $result.Logs += $log
    # Script 为空时 Arguments 自带 -EncodedCommand，用于要传数组参数的步骤。
    $invoke = if ($Script) { @('-File',$Script) + $Arguments } else { $Arguments }
    Write-StepProgress ('开始 ' + $Name)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive @invoke 2>&1 | Out-String
    $script:stepExit = $LASTEXITCODE
    $result.StepSeconds[$Name] = [math]::Round($watch.Elapsed.TotalSeconds,1)
    Write-StepProgress ($(if ($script:stepExit -eq 0) { '完成 ' } else { '失败 ' }) + $Name + '（' + $result.StepSeconds[$Name] + ' 秒）')
    $output | Set-Content -LiteralPath $log -Encoding utf8
    Save-Result
    if ($script:stepExit -ne 0 -and -not $AllowFailure) { throw ($Name + ' 失败；详情：' + $log) }
    return $output
}
function Remove-UsedPackages([string]$KeepVersion) {
    # 只删两个固定目录里 Claude-<版本>.msix 形态的安装包；更新成功后它们不再参与恢复或降级。
    # 每个目录保留版本最高的两个包（刚装的新版和刚被替换的旧版），只删更老的：
    # 刚参与安装的包删除很慢（10-14 约 96 秒、10-15 124.9 秒、10-23 删刚被替换的旧版 175.8 秒），放凉后约 1 秒。
    $removed = @(); $kept = @(); $errors = @()
    # Codex 等 MSIX 打包应用发起时，下载目录被重定向到 Packages\<包>\LocalCache\Local，一并清理。
    $directories = @((Join-Path $env:ProgramData 'ClaudeNetworkGuard'),(Join-Path $env:LOCALAPPDATA 'ClaudeNetworkGuard\Desktop安装包下载')) + @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages\*\LocalCache\Local\ClaudeNetworkGuard\Desktop安装包下载') -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName)
    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory)) { continue }
        $files = @(Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -match '^Claude-(\d+(\.\d+){3}|download-\d{8}-\d{6})\.msix$' })
        $newest = @($files | Where-Object { $_.Name -match '^Claude-\d+(\.\d+){3}\.msix$' } | Sort-Object { [version]($_.BaseName -replace '^Claude-') } -Descending | Select-Object -First 2 | ForEach-Object Name)
        foreach ($file in $files) {
            if ($file.Name -in $newest -or ($KeepVersion -and $file.Name -ieq ('Claude-' + $KeepVersion + '.msix'))) { $kept += $file.FullName; continue }
            try { Remove-Item -LiteralPath $file.FullName -Force; $removed += [pscustomobject]@{Path=$file.FullName;SizeMB=[math]::Round($file.Length/1MB,1)} }
            catch { $errors += ($file.FullName + '：' + $_.Exception.Message) }
        }
    }
    [ordered]@{Removed=$removed;Kept=$kept;Errors=$errors}
}
try {
    foreach ($value in @($PackagePath,$ApprovedSHA256,$ResumeJournal,$ResultDirectory,$ExpectedUserSid,$PluginApprovedSHA256) + @($CliApprovedSHA256)) { $null = Quote-Literal $value }
    if ($PluginApprovedSHA256) {
        if ($Action -ne 'Update') { throw 'PluginApprovedSHA256 只用于 Update。' }
        if ($PluginApprovedSHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'PluginApprovedSHA256 必须是一个 SHA256。' }
    }
    if ($CliApprovedSHA256) {
        if ($Action -ne 'Update') { throw 'CliApprovedSHA256 只用于 Update。' }
        if (@($CliApprovedSHA256).Count -ne 4 -or @($CliApprovedSHA256 | Where-Object { $_ -notmatch '^[a-fA-F0-9]{64}$' }).Count) { throw 'CliApprovedSHA256 必须是按清单顺序的四个 SHA256。' }
    }
    if (-not $ResultDirectory) { $ResultDirectory = Join-Path $env:LOCALAPPDATA ('ClaudeNetworkGuard\统一维护-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')) }
    $ResultDirectory = [IO.Path]::GetFullPath($ResultDirectory)
    $null = New-Item -ItemType Directory -Path $ResultDirectory -Force
    $resultPath = Join-Path $ResultDirectory '结果.json'
    Save-Result
    Assert-Closed
    if ($Action -eq 'Update') {
        if (-not $PackagePath -and -not $CliApprovedSHA256 -and -not $PluginApprovedSHA256) { throw 'Update 至少要提供 Desktop 安装包（PackagePath + ApprovedSHA256）、CliApprovedSHA256 或 PluginApprovedSHA256。' }
        if ($PackagePath) {
            if ($ApprovedSHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw '更新前必须提供已审核的官方 MSIX 路径和 ApprovedSHA256；由 更新三端Claude.ps1 下载审核后传入。' }
            $PackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
            if ([IO.Path]::GetExtension($PackagePath) -ine '.msix' -or (Get-FileHash -LiteralPath $PackagePath).Hash -ne $ApprovedSHA256) { throw '安装包类型或审核哈希不符。' }
        }
        if ($ResumeJournal) { $ResumeJournal = (Resolve-Path -LiteralPath $ResumeJournal).Path }
    }
    # Docs 是唯一维护源；向上找项目根，再定位 Docs 里的防护目录。
    $root = [IO.DirectoryInfo]$PSScriptRoot
    $relativeSource = 'Docs\配置\Claude环境\Desktop防护'
    while ($null -ne $root -and -not (Test-Path -LiteralPath (Join-Path $root.FullName $relativeSource))) { $root = $root.Parent }
    if ($null -eq $root) { throw '找不到同项目的 Docs 维护源；停止。' }
    $source = Join-Path $root.FullName $relativeSource
    $entry = Join-Path $source '一键更新ClaudeDesktop.ps1'
    if ($Worker) {
        if (-not $admin -or -not $ExpectedUserSid -or $ExpectedUserSid -ne $sid) { throw '管理员工作进程的用户身份不符；不能改用其他管理员账户或重复提权。' }
    } elseif (-not $admin) {
        $command = '& ' + (Quote-Literal $entry) + ' -Worker -Action ' + (Quote-Literal $Action) + ' -ResultDirectory ' + (Quote-Literal $ResultDirectory) + ' -ExpectedUserSid ' + (Quote-Literal $sid)
        foreach ($item in @{PackagePath=$PackagePath;ApprovedSHA256=$ApprovedSHA256;ResumeJournal=$ResumeJournal;PluginApprovedSHA256=$PluginApprovedSHA256}.GetEnumerator()) {
            if ($item.Value) { $command += ' -' + $item.Key + ' ' + (Quote-Literal $item.Value) }
        }
        if ($CliApprovedSHA256) { $command += ' -CliApprovedSHA256 ' + ((@($CliApprovedSHA256) | ForEach-Object { Quote-Literal $_ }) -join ',') }
        if ($ChangedOnly) { $command += ' -ChangedOnly' }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        try { $child = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -Verb RunAs -WindowStyle Hidden -PassThru }
        catch { throw ('管理员授权被取消或无法启动；未重试提权。' + $_.Exception.Message) }
        $child.WaitForExit()
        $child.Refresh()
        $saved = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        Write-Output ('ResultPath=' + $resultPath)
        if ($child.ExitCode -ne 0 -or $saved.Status -notin @('passed','passed_with_warnings')) { throw ('维护失败或未完成：' + $saved.Error) }
        Write-Output ('完成；状态：' + $saved.Status + '；没有启动 Claude Desktop 或 Claude Code。')
        exit 0
    }
    $result.UACWorker = $true
    $result.UserSid = $sid
    $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Claude'
    $result.Disabled = ($policy.disableAutoUpdates -eq 1)
    $result.Proxy = [string]$policy.egressProxyUrl
    if (-not $result.Disabled -or $result.Proxy -ne "http://127.0.0.1:$desktopPort") { throw "禁更策略或 $desktopPort 专用代理策略不符。" }
    foreach ($ifeo in @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\claude.exe','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\claude.exe')) {
        if (Test-Path -LiteralPath $ifeo) {
            foreach ($key in @((Get-Item -LiteralPath $ifeo)) + @(Get-ChildItem -LiteralPath $ifeo -Recurse)) {
                if ('Debugger' -in $key.GetValueNames()) { throw '检测到 Claude IFEO Debugger；保留现场并停止。' }
            }
        }
    }
    Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
    $packages = @(Get-AppxPackage -Name Claude)
    if ($packages.Count -ne 1) { throw '当前用户 Claude 安装包不唯一或不存在。' }
    $result.Version = [string]$packages[0].Version
    $updater = Join-Path $source '更新ClaudeDesktop.ps1'
    if ($Action -eq 'Update' -and $PluginApprovedSHA256) {
        # 插件换目录必须最先做：之后的 CLI 刷新要按清单路径逐个读文件，旧插件目录可能已被 VS Code 清掉。
        $null = Run-Step '插件路径迁移' (Join-Path $source '应用直连防护管理.ps1') @('-Action','MigratePlugin','-ApprovedSHA256',$PluginApprovedSHA256)
    }
    if ($Action -eq 'Update' -and $CliApprovedSHA256) {
        # 必须在 Desktop 迁移前刷新：Refresh 要求清单版本等于已装 Desktop，Apply 要求清单指纹等于磁盘文件。
        $refreshCommand = '& ' + (Quote-Literal (Join-Path $source '应用直连防护管理.ps1')) + ' -Action Refresh -SkipNetworkProbe -ApprovedSHA256 ' + ((@($CliApprovedSHA256) | ForEach-Object { Quote-Literal $_ }) -join ',')
        $refreshEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($refreshCommand))
        $null = Run-Step 'CLI指纹刷新' $null @('-EncodedCommand',$refreshEncoded)
    }
    if ($Action -eq 'Update' -and $PackagePath) {
        # 结果读文件：屏幕输出里混进任何警告都会让 ConvertFrom-Json 失败。
        $inspectPath = Join-Path $ResultDirectory '安装包检查.json'
        $null = Run-Step '安装包检查' $updater @('-Action','Inspect','-PackagePath',$PackagePath,'-ResultPath',$inspectPath)
        $inspection = Get-Content -LiteralPath $inspectPath -Raw | ConvertFrom-Json
        if ($inspection.SHA256 -ne $ApprovedSHA256 -or $inspection.OldVersion -ne $result.Version) { throw '包检查结果与审核哈希或当前版本不符。' }
        if ([version]$inspection.NewVersion -ne [version]$result.Version) {
            $cache = Join-Path $env:ProgramData 'ClaudeNetworkGuard'
            $null = New-Item -ItemType Directory -Path $cache -Force
            $cachedPackage = Join-Path $cache ('Claude-' + $inspection.NewVersion + '.msix')
            if ([IO.Path]::GetFullPath($PackagePath) -ine $cachedPackage) { Copy-Item -LiteralPath $PackagePath -Destination $cachedPackage -Force }
            if ((Get-FileHash -LiteralPath $cachedPackage).Hash -ne $ApprovedSHA256) { throw '复制后的官方包哈希不符。' }
            $applyArgs = @('-Action','Apply','-PackagePath',$cachedPackage,'-ApprovedSHA256',$ApprovedSHA256)
            if ($ResumeJournal) { $applyArgs += @('-ResumeJournal',$ResumeJournal) }
            $null = Run-Step '版本更新' $updater $applyArgs
        }
    }
    Assert-Closed
    $null = Run-Step '防护核验' (Join-Path $source '应用直连防护管理.ps1') @('-Action','Verify')
    $verified = Get-Content -LiteralPath (Join-Path $source '应用直连防护-Verify.json') -Raw | ConvertFrom-Json
    if ($verified.Status -ne 'passed' -or -not $verified.PackageVersionMatches) { throw '管理员核验证据没有通过。' }
    $result.Version = $verified.PackageVersion
    $result.HashCount = @($verified.Targets | Where-Object BinaryUnchanged).Count
    $result.FiltersCount = @($verified.Targets | ForEach-Object Filters).Count
    if ($result.HashCount -ne 4 -or $result.FiltersCount -ne 8) { throw '预期的四个程序文件或八条防护规则不完整。' }
    # 2026-10-26 起 Skill 不再保存脚本与状态副本，这里不再同步。
    $summaryArgs = @()
    if ($ChangedOnly) { $summaryArgs = @('-Scope','Guard') }
    $result.SummaryScope = if ($ChangedOnly) { 'Guard' } else { 'All' }
    $summary = Run-Step '日常总检' (Join-Path $root.FullName 'Docs\配置\Claude环境\Claude环境一键总检.ps1') $summaryArgs -AllowFailure
    $summaryExit = $script:stepExit
    $result.Checks = [ordered]@{PASS=0;WARN=0;FAIL=0;MANUAL=0}
    foreach ($label in @('PASS','WARN','FAIL','MANUAL')) { $result.Checks[$label] = [regex]::Matches($summary, ('(?m)^\[' + $label + '\s*\]')).Count }
    if ($summaryExit -ne 0 -or $result.Checks.FAIL -gt 0 -or $result.Checks.PASS -eq 0) { throw '日常总检存在失败；详见本次日志。' }
    $null = Run-Step '启动条件检查' (Join-Path (Split-Path $source -Parent) '启动Claude英文浏览器.ps1') @('-CheckOnly')
    Assert-Closed
    # 只在全部核验通过后清理；失败时安装包要留给 -ResumeJournal 续接。
    if ($Action -eq 'Update') {
        # 单独计时：刚参与安装的包删得慢，现在每个目录保留最新两个版本，只删更老的。
        Write-StepProgress '开始 安装包清理'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result.Cleanup = Remove-UsedPackages -KeepVersion $result.Version
        $result.StepSeconds['安装包清理'] = [math]::Round($watch.Elapsed.TotalSeconds,1)
        Write-StepProgress ('完成 安装包清理（' + $result.StepSeconds['安装包清理'] + ' 秒）')
        if ($result.Cleanup.Errors.Count) { $result.Checks.WARN++ }
    }
    $result.Status = if ($result.Checks.WARN -gt 0) { 'passed_with_warnings' } else { 'passed' }
    Save-Result
    Write-Output ('ResultPath=' + $resultPath)
    Write-Output '完成；未启动应用；网页人工验收单独记录。'
} catch {
    $result.Status = 'failed'
    $result.Error = $_.Exception.Message
    if ($resultPath) {
        # 子进程已写下的现场证据优先，父进程不能用空壳结果覆盖它。
        if (-not $child) { Save-Result }
        Write-Output ('ResultPath=' + $resultPath)
    }
    Write-Error -Message $result.Error -ErrorAction Continue
    exit 1
}
