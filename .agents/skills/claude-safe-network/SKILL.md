---
name: claude-safe-network
description: Claude Code / Claude Desktop 安全出口链路的核对、验收、变更与排障（Clash Verge Rev + TUN + 全局扩展脚本架构）。当用户要检查 Claude 网络配置是否安全稳定、验证三个专用入口（43865 Claude Code / 43866 专用 Chrome / 43867 Desktop）是否走同一个出口、换订阅或换节点后复核、改端口或改组名、新建账号专用浏览器、回滚 Clash 配置，或排查 Claude 连不上 / 规则失效 / DNS 泄漏 / 直连旁路时使用。触发词：Claude 安全配置、Clash 出口、ACCOUNT-US、43865、43866、43867、egressProxyUrl、直连阻断、WFP、换订阅复核、一键总检、环境卫士、TUN 规则、代理配置检查、MTU、回滚。Claude 三端更新走 claude-maintenance。
---

# Claude 安全出口链路

> **边界**：变更与更新由用户手动完成；模型只做核对、审查和报告，不重启或热重载 Clash，不启动或退出 Claude，除非用户当次明确要求。
> **脚本位置**：所有脚本、状态文件只在项目的 `docs/配置/Claude环境/` 一处（2026-10-26 整合后，本 Skill 只放说明，不再保存副本）。下面命令路径都相对项目根，一律用 pwsh 7。

## 30 秒认知

1. **配置主体是 Clash Verge Rev 的全局扩展脚本** `Script.js`（权威副本 `docs/配置/Claude环境/Clash/Clash全局账号通道.js`），跟订阅解耦，换订阅自动适配。
2. **三个端口三条腿**：`43865` Claude Code（HTTP）、`43866` 专用 Chrome（SOCKS5）、`43867` Claude Desktop（HTTP），必须汇到同一个出口 IP。
3. **只代理 Claude，不做全局代理**：TUN + 规则分流，系统代理关闭。
4. **兜底四层**：置顶规则兜「走错组」、TUN strict-route + 53 劫持兜「DNS 旁路」、WFP 精确阻断兜「Claude 程序绕开代理直连」、防火墙网段阻断兜「任何程序直连 `160.79.104.0/23`」。
5. **日常检查用环境卫士**（`D:\Tools\ClaudeEnvGuard`，30 项）；卫士查不到的 Clash 内部项由一键总检补齐（卫士「深度总检」调的就是它）。

```
Claude Code ──HTTP──┐
专用 Chrome ─SOCKS5─┼──► Clash Verge Rev ──► ACCOUNT-US 代理组 ──► 美国住宅出口
Claude Desktop─HTTP─┘        (mihomo)          (手工选线路)
   43865 / 43866 / 43867          │
                                  ├─ 置顶规则：Claude/Anthropic 域名 + IP-ASN 399358
                                  ├─ DNS：Claude 专属域名走 DoH over ACCOUNT-US
                                  ├─ TUN：strict-route + dns-hijack(any:53)
                                  └─ WFP：8 条精确阻断（4 个 claude.exe × V4/V6）
```

## 常用命令

| 要做什么 | 命令 |
|---|---|
| 一键总检（只读；`-OpenBrowser` 会打开日常专用 Chrome，运行前先告知用户） | `pwsh -NoProfile -File docs/配置/Claude环境/Claude环境一键总检.ps1` |
| Desktop 启动门禁（只检查不启动） | `pwsh -NoProfile -File docs/配置/Claude环境/启动Claude英文浏览器.ps1 -CheckOnly` |
| Anthropic 网段阻断：检查 / 安装（安装需管理员，用户做） | `pwsh -NoProfile -File docs/配置/Claude环境/Anthropic网段直连阻断.ps1 [-Action Install]` |
| Claude 官方域名每周复核 | `pwsh -NoProfile -File docs/配置/Claude环境/Clash/检查Claude官方域名.ps1` |
| 改了脚本或文档后自检 | `pwsh -NoProfile -File docs/配置/Claude环境/工具/检查脚本完整性.ps1` |
| 新建账号专用 Chrome | `pwsh -NoProfile -File docs/配置/Claude环境/工具/创建账号浏览器.ps1 -Alias <别名>`（说明见 `docs/配置/Claude环境/说明/账号浏览器.md`） |
| 回滚 Clash 账号通道 | `pwsh -NoProfile -File docs/配置/Claude环境/工具/回滚Clash配置.ps1 -BackupDirectory <备份目录>` |
| `.ps1` 右键「用 PowerShell 7 运行」：查看 / 加 / 撤 | `pwsh -NoProfile -File docs/配置/Claude环境/工具/启用-PowerShell7入口.ps1 [-Apply / -Rollback]` |

`docs/配置/Claude环境/工具/` 里另有 `安装Clash账号专用通道.ps1`、`修复Clash全机DNS.ps1`、`更新Clash通用规则.ps1`（会重启 Clash，需 `CLAUDE_ALLOW_CLASH_RESTART=1`），都是已执行过的一次性工具，只在重建环境时由用户决定是否运行。

**判定**：以脚本实时输出为准，`0 FAIL`、退出码 `0` 即通过，`WARN` 逐条确认，`MANUAL` 是用户的网页人工验收。

## 场景

| 场景 | 做法 |
|---|---|
| 用户问「现在安全吗」 | 让用户看环境卫士体检；需要更深时跑一键总检。有 FAIL 按 [02 决策树](references/02-验收与排查手册.md#3-故障决策树) 查 |
| 换订阅 / 换节点 | [03 SOP-1](references/03-变更与回滚SOP.md#sop-1-导入新订阅或换节点后复核)：脚本规则不用改，只需手动选节点再复核 |
| Claude 三端更新 | 走 [claude-maintenance](../claude-maintenance/SKILL.md) |
| 改端口 / 改组名 | [03 SOP-3](references/03-变更与回滚SOP.md#sop-3-改端口或改组名) |
| 连不上 / 疑似泄漏 | **国内网站正常、走代理的全挂**时先跑 `ping -f -l 1472 8.8.8.8`，超时就是 MTU 黑洞（决策树第 -1 步），不换订阅不换节点；其余按决策树走 |
| 要撤销变更 | [03 SOP-4](references/03-变更与回滚SOP.md#sop-4-回滚) |

## 硬红线

- ❌ 不把订阅 URL token、节点 uuid、REALITY public-key、真实出口 IP 写进任何回复 / 文档 / 提交。
- ❌ 不读、不打印 `~/.claude/.credentials.json`、`~/.claude/settings.json`、Clash `profiles.yaml` 的订阅详情。
- ❌ 不承诺「规避检测 / 伪装流量」；只做「出口干净 + 不泄漏 + 不旁路」。
- ❌ 没有用户明确要求时不主动跑 IP 检测、不解读检测站结果。
- ❌ 不因为一份不完整的枚举就否定「已验证通过」的结论 —— 先怀疑自己的取证方法（见下）。

## 误判坑

| 坑 | 错误做法 | 正确做法 |
|---|---|---|
| **注册表** | 去查 `HKLM\SOFTWARE\Policies\Anthropic\Claude` | 真实路径是 `HKLM\SOFTWARE\Policies\Claude`（没有 `Anthropic` 层） |
| **防火墙** | 把两个直连阻断机制混为一谈 | Claude 程序的 WFP 精确过滤器不在 `Get-NetFirewallRule` 里；`160.79.104.0/23` 的系统出站规则在防火墙规则表里，用 `Anthropic网段直连阻断.ps1` 核对 |
| **运行脚本** | 用 Windows PowerShell 5.1 跑 | 必须 pwsh 7：脚本是无 BOM UTF-8，5.1 按 GBK 读会整片解析失败；5.1 与 7 共存不是冲突，不要卸载 5.1 |
| **网段** | 以为 `/21` 和 `/23` 有一个写错 | Clash 用 `160.79.104.0/21` 分流，防火墙用 `160.79.104.0/23` 阻断，是两件事 |

## 参考文件

| 文件 | 内容 |
|---|---|
| [references/01-架构与配置主体.md](references/01-架构与配置主体.md) | `Script.js` 六步逻辑、Claude Code / Desktop 配置、WFP、关键路径 |
| [references/02-验收与排查手册.md](references/02-验收与排查手册.md) | 验收入口与合格线、IP 站判读、故障决策树、环境坑、「不是问题」清单 |
| [references/03-变更与回滚SOP.md](references/03-变更与回滚SOP.md) | 换订阅、三端更新指路、改端口、回滚、变更后收尾 |
| `docs/配置/Claude环境/README.md` | 本机现状、目录、按任务阅读入口 |
