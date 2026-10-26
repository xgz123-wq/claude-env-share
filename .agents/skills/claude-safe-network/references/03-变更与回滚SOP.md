# 变更与回滚 SOP

> 总原则：**能只改开关就不改文件；能只改全局脚本就不碰订阅。** 每次变更后跑一键总检（SOP-5）。
> 命令里的路径都相对项目根；脚本只在 `docs/配置/Claude环境/` 一处（2026-10-26 起 Skill 不再放脚本副本）。
> Claude 域名的每周与更新后复核只维护在 [DNS分层说明](../../../../docs/配置/Claude环境/说明/DNS分层说明.md#claude-域名定期复核)。

| SOP | 什么时候用 | 要动系统吗 |
|---|---|---|
| [SOP-1](#sop-1-导入新订阅或换节点后复核) | 导入新订阅 / 换节点后 | 否 |
| [SOP-2](#sop-2-claude-三端更新) | Desktop / CLI / VS Code 插件更新 | 一次 UAC，由用户点 |
| [SOP-3](#sop-3-改端口或改组名) | 改端口 / 改组名 | 是，用户手动改 |
| [SOP-4](#sop-4-回滚) | 撤销某项变更 | 视变更而定 |
| [SOP-5](#sop-5-变更后必须做的事) | 任何变更后的收尾 | 否 |

## SOP-1 导入新订阅或换节点后复核

**脚本与规则一行都不用改**：`Script.js` 的 `ACCOUNT-US` 组声明了 `include-all-proxies: true`，自动吃下新订阅全部节点；Claude 置顶规则是全局注入的，与订阅无关；新订阅自带的 Claude 规则会被 `isManagedClaudeRule()` 自动清掉。

| 步 | 做什么 | 期望 | 不通过怎么办 |
|---|---|---|---|
| 1 | 在 Clash 里给 `ACCOUNT-US` 手动挑一个节点（用户做） | 组非空、已选中 | 自动填充不会自动选中；组为空说明新订阅没有可用节点 |
| 2 | 跑一键总检 | `0 FAIL`，三入口出口一致 | 按 [02 决策树](02-验收与排查手册.md#3-故障决策树) 查 |
| 3 | 环境卫士「体检」看 P3–P5（三入口出口、地区、IP 质量） | 全绿 | 命中机房 / 黑名单就换节点 |
| 4 | 用户在专用 Chrome 里人眼看检测站（判读见 [02 §2](02-验收与排查手册.md#2-ip-信誉站的判读标准)） | 页面 IP 与总检一致 | 不一致说明某个入口没走 `ACCOUNT-US` |

**不要做**：系统环境变量里设 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` / `ANTHROPIC_BASE_URL`；给 Claude 设 `ANTHROPIC_BASE_URL` 指向中转；TUN 开着时再开系统代理；Claude 使用期间狂切节点或国家。没有用户明确要求时不主动跑 IP 检测。

## SOP-2 Claude 三端更新

流程只维护在 [claude-maintenance](../../claude-maintenance/SKILL.md) 与 [更新维护说明](../../../../docs/配置/Claude环境/Desktop防护/更新维护说明.md)。要点：Desktop 是 MSIX，升级会换 `WindowsApps\Claude_<版本>_x64__pzs8sxrjxfjjc` 目录，WFP 精确阻断按 exe 完整路径匹配，路径一变规则就全部失效且不报错，所以更新必须走 `更新三端Claude.ps1`（它在同一次 UAC 里迁移防护并做管理员 Verify）。

更新后顺带核对：

- `HKLM\SOFTWARE\Policies\Claude` 里 `disableAutoUpdates=1` 与 `egressProxyUrl=http://127.0.0.1:43867` 同层同时存在（总检会查）。
- `%LOCALAPPDATA%\Claude-3p\configLibrary\_meta.json` 的 `appliedId` 指向有效文件。
- `pwsh -File docs/配置/Claude环境/启动Claude英文浏览器.ps1 -CheckOnly` 全是 `[PASS]`。

## SOP-3 改端口或改组名

**不建议改。** 改之前先列出所有出现位置，逐个改、逐个验：

```bash
grep -rn "43865\|43866\|43867" docs/配置/Claude环境 --include=*.ps1 --include=*.js --include=*.md
```

| 位置 | 内容 | 谁改 |
|---|---|---|
| `docs/配置/Claude环境/Clash/Clash全局账号通道.js` → 现场 `Script.js` | listener 端口、组名、规则目标、DNS policy 的 `#ACCOUNT-US` | 用户在 Clash 里更新全局脚本 |
| `~\.claude\settings.json` | `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` | 用户 |
| 各专用 Chrome 快捷方式 | `--proxy-server=socks5://127.0.0.1:43866` | 用户 |
| `HKLM\SOFTWARE\Policies\Claude`、`configLibrary` profile | `egressProxyUrl` | 用户（管理员） |
| docs 脚本里的字面量 | 上面 grep 列出的文件:行号 | 模型 |
| 环境卫士 `设置.json` | 三个端口 | 用户在卫士设置页 |

改完跑 SOP-5。若改了 Desktop 端口，还要确认英文启动器 `-CheckOnly` 通过。

## SOP-4 回滚

- **Clash 账号通道**：`account-routing-backups\`（在 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\` 下）存着每次改动前的配置；用 `pwsh -File docs/配置/Claude环境/工具/回滚Clash配置.ps1 -BackupDirectory <备份目录>`，它会先校验再热重载。

| 备份目录 | 对应操作 | 状态记录 |
|---|---|---|
| `20260910-121858-ClaudeDesktop专用入口` | 09-10 Desktop 专用通道建立 | `Desktop防护/安装状态.json` |
| `20260910-140516-共用DNS修复` | 09-10 共用 DNS 修复 | `Desktop防护/共用DNS修复状态.json` |

- **WFP 直连防护**：`Desktop防护/应用直连防护管理.ps1 -Action Rollback`（管理员）。
- **Anthropic 网段阻断**：规则名 `Claude-Anthropic-Direct-Block-160.79.104.0-23`，删规则即回滚（管理员）。
- **PS7 右键入口**：`pwsh -File docs/配置/Claude环境/工具/启用-PowerShell7入口.ps1 -Rollback`（只写 HKCU）。
- **本仓库脚本与文档**：每次维护前的备份在 `%LOCALAPPDATA%\ClaudeNetworkGuard\<任务名>-<时间>\`。

回滚步骤：① 停 Claude（Code + Desktop，用户做）；② 还原对应文件或跑上面的回滚命令；③ 跑 SOP-5；④ 涉及 WFP 时由用户以管理员跑 Install + Verify。

## SOP-5 变更后必须做的事

1. 一键总检，期望 `0 FAIL`：
   ```bash
   pwsh -NoProfile -File docs/配置/Claude环境/Claude环境一键总检.ps1
   ```
2. 改了脚本或文档、搬了文件：跑脚本完整性检查，期望 `0 FAIL`：
   ```bash
   pwsh -NoProfile -File docs/配置/Claude环境/工具/检查脚本完整性.ps1
   ```
3. 按 AGENTS.md 记维护日志；做法变了就同步分享包。
