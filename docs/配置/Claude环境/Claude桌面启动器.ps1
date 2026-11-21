#requires -Version 7.0
# Claude 桌面启动器（桌面「Claude-桌面启动器」；环境卫士按 -CheckOnly 调；2026-11-21 前叫 启动Claude英文浏览器.ps1，它不是浏览器）：查 Desktop 版本与直连防护、固定代理、Clash 路由、
# Desktop 端口归属与出口（Claude 眼里的国家须在部署清单「允许的出口国家」里，默认 US），全过才以 en-US 启动；关掉本窗口即退出 Claude。
# 不用管理员；-CheckOnly 只检查不启动。Claude 已在运行时拒绝（已有进程不会重新加载语言参数）。
[CmdletBinding()]
param(
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# Desktop 专用端口按名字从部署清单取（源头是 Clash全局账号通道.js 的 claude-desktop-http）。
. (Join-Path $PSScriptRoot '工具\读部署清单.ps1')
# 出口只问 Claude 自己（claude.ai/cdn-cgi/trace），和总检、巡检、通道验证共用一份。
. (Join-Path $PSScriptRoot '工具\测Claude出口.ps1')
$expectedPort = Get-DeployPort Desktop
$expectedProxy = "http://127.0.0.1:$expectedPort"
$guardDirectory = Join-Path $PSScriptRoot 'Desktop防护'
$guardManifestPath = Join-Path $guardDirectory '应用过滤目标.json'
$guardStatePath = Join-Path $guardDirectory '应用直连防护状态.json'
$guardVerifyPath = Join-Path $guardDirectory '应用直连防护-Verify.json'
$guardInstallPath = Join-Path $guardDirectory '应用直连防护-最近操作.json'
$clashRuntime = $deployClashRuntime

function Write-Pass {
    param([string]$Message)
    Write-Host ('[PASS] ' + $Message) -ForegroundColor Green
}

# 直连防护凭证判定和一键总检共用一份。
. (Join-Path $PSScriptRoot '工具\读防护凭证.ps1')

function Assert-GuardEvidence {
    param([string]$PackageVersion)

    foreach ($path in @($guardManifestPath, $guardStatePath, $guardInstallPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw 'Windows 直连防护记录不完整。'
        }
    }

    $manifest = Get-Content -LiteralPath $guardManifestPath -Raw | ConvertFrom-Json
    $state = Get-Content -LiteralPath $guardStatePath -Raw | ConvertFrom-Json
    $install = Get-Content -LiteralPath $guardInstallPath -Raw | ConvertFrom-Json
    $manifestHash = (Get-FileHash -LiteralPath $guardManifestPath -Algorithm SHA256).Hash

    $pluginProblem = Get-PluginGuardProblem $manifest.Targets
    if ($pluginProblem) { throw $pluginProblem }

    if ([string]$manifest.PackageVersion -ne $PackageVersion) {
        throw 'Claude Desktop 已更新，Windows 直连防护尚未迁移到当前版本。'
    }
    foreach ($target in @($manifest.Targets)) {
        if (-not (Test-Path -LiteralPath $target.Path)) {
            throw ('直连防护目标不存在：' + $target.Name)
        }
        if (-not (Test-GuardBinary $target)) {
            throw ('程序文件已变化，需要重新核验直连防护：' + $target.Name)
        }
    }
    if ([string]$state.Status -notlike 'installed_*' -or $state.ManifestSHA256 -ne $manifestHash) {
        throw 'Windows 直连防护安装状态与当前目标清单不一致。'
    }
    if (-not (Test-GuardRecord -RecordedTargets $state.Targets -ManifestTargets $manifest.Targets)) {
        throw 'Windows 直连防护安装记录不完整。'
    }

    $verifyReady = $false
    if (Test-Path -LiteralPath $guardVerifyPath) {
        $verify = Get-Content -LiteralPath $guardVerifyPath -Raw | ConvertFrom-Json
        $verifyReady =
            ($verify.Status -eq 'passed') -and
            ($verify.ManifestSHA256 -eq $manifestHash) -and
            ($verify.PackageVersionMatches -eq $true) -and
            (Test-GuardRecord -RecordedTargets $verify.Targets -ManifestTargets $manifest.Targets -RequireBinaryUnchanged)
    }
    $installReady =
        ($install.Action -eq 'Install') -and
        ($install.Status -eq 'passed') -and
        (Test-GuardRecord -RecordedTargets $install.Installed -ManifestTargets $manifest.Targets)
    if (-not $verifyReady -and -not $installReady) {
        throw '没有与当前版本匹配的管理员安装或 Verify 凭证。'
    }

    if ($verifyReady) { return '管理员 Verify 凭证' }
    return '管理员安装凭证'
}

# 新版 Claude Desktop 收到关窗信号只会转到后台、不真正退出，残留会挡住下次启动。
# 所以由本窗口登记一个关窗处理：窗口被关时，把这个路径的 Claude 连同子进程一起结束。
function Register-ClaudeCloseGuard {
    param([string]$ExePath)
    if (-not ('ClaudeCloseGuard' -as [type])) {
        Add-Type -TypeDefinition @"
using System; using System.Diagnostics; using System.Runtime.InteropServices;
public static class ClaudeCloseGuard {
    delegate bool Handler(int ctrlType);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(Handler h, bool add);
    static Handler keep; static string target;
    public static void Arm(string path) { target = path; keep = OnCtrl; SetConsoleCtrlHandler(keep, true); }
    static bool OnCtrl(int ctrlType) {
        if (ctrlType != 2) return false;
        foreach (var p in Process.GetProcessesByName("claude")) {
            try { if (string.Equals(p.MainModule.FileName, target, StringComparison.OrdinalIgnoreCase)) p.Kill(true); } catch {}
        }
        return false;
    }
}
"@
    }
    [ClaudeCloseGuard]::Arm($ExePath)
}

function Assert-ClashRoute {
    if (-not (Test-Path -LiteralPath $clashRuntime)) {
        throw '找不到 Clash 当前运行配置。'
    }
    $text = Get-Content -LiteralPath $clashRuntime -Raw
    $listenerMatches = [regex]::Matches($text, '(?ms)^- name:\s*claude-desktop-http\s*$.*?(?=^- name:|\z)')
    if ($listenerMatches.Count -ne 1) {
        throw 'Clash 当前配置中的 Claude Desktop 专用入口缺失或重复。'
    }
    $listenerBlock = $listenerMatches[0].Value
    $listenerReady =
        ($listenerBlock -match '(?m)^\s*type:\s*http\s*$') -and
        ($listenerBlock -match '(?m)^\s*listen:\s*127\.0\.0\.1\s*$') -and
        ($listenerBlock -match "(?m)^\s*port:\s*$expectedPort\s*`$") -and
        ($listenerBlock -match '(?m)^\s*proxy:\s*ACCOUNT-US\s*$')
    if (-not $listenerReady) {
        throw "Clash 的 $expectedPort 没有完整固定到 ACCOUNT-US。"
    }

    $groupMatches = [regex]::Matches($text, '(?ms)^- name:\s*ACCOUNT-US\s*$.*?(?=^- name:|\z)')
    if ($groupMatches.Count -ne 1) {
        throw 'Clash 当前配置中的 ACCOUNT-US 组缺失或重复。'
    }
    $groupBlock = $groupMatches[0].Value
    if ($groupBlock -notmatch '(?m)^\s*exclude-type:\s*Direct\|Reject\s*$') {
        throw 'ACCOUNT-US 没有排除 Direct/Reject，已拒绝启动 Claude。'
    }
}

try {
    $package = Get-AppxPackage -Name Claude | Select-Object -First 1
    if (-not $package) { throw '找不到 Claude Desktop 安装包。' }
    $exe = Join-Path $package.InstallLocation 'app\Claude.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw '找不到 Claude Desktop 主程序。' }

    $running = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
    if ($running.Count) { throw '请先完全退出 Claude Desktop，再使用这个入口。已有进程不会重新加载语言参数。' }

    $proxy = Get-DesktopProxySetting
    if ($proxy.Problem) { throw ('无法确认 Claude Desktop 固定代理：' + $proxy.Problem + '。') }
    if ($proxy.Value -ne $expectedProxy) {
        throw "Claude Desktop 固定代理不正确：$($proxy.Source) 当前不是 $expectedProxy。"
    }
    Write-Pass "固定代理：$($proxy.Source) -> $expectedProxy"

    Assert-ClashRoute
    Write-Pass "Clash 路由：$expectedPort -> ACCOUNT-US，且排除 Direct/Reject"

    $listeners = @(Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort $expectedPort -ErrorAction SilentlyContinue)
    if (-not $listeners.Count) {
        throw "Claude 专用代理 $expectedPort 未开启，已拒绝启动 Claude。"
    }
    $ownerNames = @($listeners.OwningProcess | Select-Object -Unique | ForEach-Object {
        (Get-Process -Id $_ -ErrorAction Stop).ProcessName
    } | Select-Object -Unique)
    if ($ownerNames.Count -ne 1 -or $ownerNames[0] -ne 'verge-mihomo') {
        throw ("$expectedPort 不是由 Clash 内核 verge-mihomo 提供，已拒绝启动 Claude。当前：" + ($ownerNames -join ', '))
    }
    Write-Pass "$expectedPort 正在监听，且归属 verge-mihomo"

    $guardEvidence = Assert-GuardEvidence -PackageVersion $package.Version.ToString()
    Write-Pass "Windows 直连防护记录有效：$guardEvidence；Claude Desktop $($package.Version) 与规则匹配"

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw '找不到 curl.exe，无法验证专用代理是否真正可用。'
    }
    $trace = Get-ClaudeTrace -Type http -Port $expectedPort -Attempts 2
    if (-not $trace.Succeeded) {
        throw "$expectedPort 虽已监听，但经它连不上 Claude（claude.ai/cdn-cgi/trace），已拒绝启动 Claude。"
    }
    $allowedCountries = Get-DeployExitCountries
    if ($trace.Loc -notin $allowedCountries) {
        throw "$expectedPort 出口在 Claude 眼里是 $($trace.Loc)，不在允许的出口国家（$($allowedCountries -join '、')）里，已拒绝启动 Claude；检查 ACCOUNT-US 选的节点。"
    }
    Write-Pass "$expectedPort 代理连通，Claude 看到的出口：$($trace.IP)（$($trace.Loc)）"

    if ($CheckOnly) {
        Write-Host '结论：启动前检查全部通过；本次只检查，没有启动 Claude。' -ForegroundColor Cyan
        exit 0
    }

    Register-ClaudeCloseGuard -ExePath $exe
    Start-Process -FilePath $exe -ArgumentList '--lang=en-US','--accept-lang=en-US,en'
    Write-Host '启动前检查全部通过，已用英文界面启动 Claude Desktop。' -ForegroundColor Green
    Write-Host '关闭本窗口 = 退出 Claude（连同后台进程一起结束）；从托盘退出 Claude 后本窗口自动关闭。'
    # 守到 Claude 退出：窗口始终在，关窗处理才有机会执行。
    while (Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object Path -eq $exe) {
        Start-Sleep -Seconds 2
    }
} catch {
    Write-Host ('[BLOCK] ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '结论：已拒绝启动 Claude；没有放行真实 IP 直连。' -ForegroundColor Yellow
    if (-not $CheckOnly) {
        Read-Host '按回车关闭'
    }
    exit 1
}
