# Claude 配置总览

> 更新日期：2026-10-06
> `docs/配置/Claude环境/` 是 Claude/Clash 配置的唯一位置；桌面快捷方式和总检按「脚本目录往上 3 层 = 项目根」定位，不要改目录名或层级。

## 目录

| 位置 | 内容 |
|---|---|
| `Claude环境一键总检.ps1` | 桌面「Claude-环境一键总检」，只做检查；顺带按 Clash 刷新[部署清单](#部署清单) |
| `部署清单.示例.json` | 部署清单的格式与默认端口（相当于 `.env.example`）；本机清单不在这里 |
| `Anthropic网段直连阻断.ps1` | 检查或安装 `160.79.104.0/23` 出站阻断规则；默认只读 |
| `启动Claude英文浏览器.ps1`、`Claude官方图标.ico` | 桌面「Claude-英文浏览器」，检查通过才启动 Desktop |
| `Clash/` | Clash 全局脚本副本（与现场 `Script.js` 一致）、通道验证脚本、官方域名复核脚本 |
| `Desktop防护/` | Desktop/Code 直连防护、三端更新入口（`更新三端Claude.ps1`，桌面「Claude-三端更新」）、Desktop 受控更新、43867 通道管理、自动更新开关，以及运行状态 json |
| `工具/` | `检查脚本完整性.ps1`（改了脚本或文档后跑）；`读部署清单.ps1`、`写部署清单.ps1`（各脚本共用，见[部署清单](#部署清单)）；一次性工具：安装账号通道、修复 DNS、更新 Clash 通用规则、创建账号浏览器、回滚 Clash 配置、PS7 右键入口 |
| `说明/` | [日常使用](说明/日常使用.md)、[Anthropic 网段直连阻断](说明/Anthropic网段直连阻断.md)、[账号浏览器](说明/账号浏览器.md)、[DNS 分层](说明/DNS分层说明.md)、[架构讲解](说明/架构讲解.html)（图解，双击打开） |
| `维护日志.md` | 最近一轮维护的结论与证据，更早的压成历史表 |
| `清理维护残留.ps1` | 列出并清理过期备份与遗留安装包（默认只列清单，加 `-Yes` 才删） |

- **Skill**：[claude-safe-network](../../../.agents/skills/claude-safe-network/SKILL.md) 是给 AI 的排障说明，命令都指回本目录；一次性工具在 `工具/`。

## 当前状态（原机器 2026-09-25 参考值，新机器以实测为准）

| 项目 | 现状 |
|---|---|
| Claude Desktop | `2.9939.2.0`，自动更新关闭 |
| Claude Code CLI | `2.1.282`，指纹已同步 |
| Claude Code VS Code 插件 | 安装后固定版本，并把当前插件内置 `claude.exe` 路径纳入防护 |
| 直连防护 | 4 个程序、8 条 WFP 规则 |
| 验证 | 一键总检 13 PASS / 1 MANUAL（2026-09-25） |

端口是默认值，本机以[部署清单](#部署清单)为准：

| 入口 | 路线 |
|---|---|
| Claude Code CLI / VS Code 插件 | HTTP `43865`，Claude 域名按规则进 `ACCOUNT-US` |
| 专用 Chrome | SOCKS `43866 → ACCOUNT-US` |
| Claude Desktop | HTTP `43867 → ACCOUNT-US` |

## 部署清单

- **是什么**：本机端口和路径的唯一记录，作用相当于这套环境的 `.env`，位置 `%LOCALAPPDATA%\ClaudeNetworkGuard\部署清单.json`；不进 git、不进分享包，格式和默认值见 `部署清单.示例.json`。
- **内容**：三个端口（`通用` = Clash 混合端口，默认 43865；`浏览器` = 专用 Chrome 的 SOCKS，默认 43866；`Desktop` = Claude Desktop 的 HTTP，默认 43867）、脚本根目录、登记的专用浏览器（别名、数据目录、快捷方式）。
- **谁写**：一键总检每次运行从 Clash 运行配置 `clash-verge.yaml` 读端口（`mixed-port` 和 `account-us-socks` / `claude-desktop-http` 两个 listener）、扫桌面专用浏览器后刷新，内容没变不写；`工具/创建账号浏览器.ps1` 建完登记。两者都调 `工具/写部署清单.ps1`。
- **谁读**：脚本点源 `工具/读部署清单.ps1` 后用 `Get-DeployPort 通用|浏览器|Desktop` 按名字取端口；清单不存在、读坏或缺某项时用示例默认值，并往 stderr 提示一行。环境卫士（v2.6.0 起）只读不写：端口、分享包位置、专用浏览器都先看清单，再实际核对。
- **专用浏览器认定**：当前用户桌面上、参数含 `%LOCALAPPDATA%\ClaudeAccountBrowsers\<别名>\UserData` 的快捷方式，规则只写在 `读部署清单.ps1` 一处，总检和清单共用。
- **改端口**：端口的源头是 Clash（混合端口在 Clash Verge 设置里，`浏览器`、`Desktop` 两个专用端口在 `Clash/Clash全局账号通道.js`），只在 Clash 一侧改，再跑一次一键总检刷新清单；不要手改清单，也不用改脚本。完整步骤见 Skill [claude-safe-network SOP-3](../../../.agents/skills/claude-safe-network/references/03-变更与回滚SOP.md#sop-3-改端口或改组名)。
- **仍写着默认端口的**：`部署清单.示例.json`（回退值）、`Desktop防护/独立网络探针.cjs`（打包成探针 exe，直连防护 Install / Verify 时用）、Clash 的 JS（端口定义处）；文档里的端口一律指默认值。

## 按任务阅读

| 要做什么 | 入口 |
|---|---|
| 理解整体架构、出问题定位到哪一层 | [架构讲解](说明/架构讲解.html) |
| 每天启动与检查 | [日常使用](说明/日常使用.md) |
| 每周或更新后复核 Claude 域名 | 运行 `Clash/检查Claude官方域名.ps1`；分工与新域名处理见 [DNS 分层与域名维护](说明/DNS分层说明.md#claude-域名定期复核) |
| 安装或检查 Anthropic 网段直连阻断 | [Anthropic 网段直连阻断](说明/Anthropic网段直连阻断.md)；首次部署后总检会验证 |
| 更新 Desktop / CLI / 插件，或手动更新后补同步 | 退出全部 Claude 后双击桌面「Claude-三端更新」（= `Desktop防护/更新三端Claude.ps1`），一次 UAC 做完；只想看要不要更新跑 `-Action Check`；CLI 自更新后不用同步；分流规则见 [claude-maintenance](../../../.agents/skills/claude-maintenance/SKILL.md#先分流更新后要做什么) |
| Desktop 更新细则 | [更新维护说明](Desktop防护/更新维护说明.md) |
| 网络排障、改端口；换订阅后的复核流程 | Skill [claude-safe-network](../../../.agents/skills/claude-safe-network/SKILL.md) |
| 历次维护与未验收项 | [维护日志](维护日志.md) |

## 约定

- **维护默认**：不启动 Desktop、Code 或浏览器；不改 Clash 生效配置、`ACCOUNT-US` 手选节点、DNS、HKLM 策略。
- **验收边界**：程序层检查通过不等于真实网页、登录和外部工具都已验证；旧截图、旧版号、旧 IP 不能替代现场检查。

## 部署参考（分享版）

> 本节只在分享版维护，从主项目同步本文件时保留本节。

### 规则匹配顺序

规则从上往下匹配，命中即停：

| 顺序 | 规则 | 作用 |
|---|---|---|
| 1 | `IN-NAME,account-us-socks,ACCOUNT-US` | 从 `43866` 进来的连接直接入组 |
| 2 | Claude 域名 / IP 段 / ASN | Claude 流量入组，优先于后面所有规则 |
| 3 | 浏览器 DoH 端点 → `DIRECT` | 防浏览器自带加密 DNS 被兜底规则送出国，把国内域名解析成海外 IP |
| 4 | 订阅原有规则（`GEOSITE,cn` / `GEOIP,CN` → `DIRECT` 等） | 国内流量直连，不绕美国 |
| 5 | `MATCH,Proxy` | 其余走订阅兜底组 |

- **现场核对**：打开 Clash Verge 的「连接」页搜 `anthropic`，命中的应是 `ACCOUNT-US`。

### 系统层的三道硬拦

与规则无关，独立生效：

| 层 | 拦什么 | 怎么来 |
|---|---|---|
| 防火墙规则 | 出站阻断 `160.79.104.0/23`，任何程序直连 Anthropic 官方 IP 都被拦 | AGENTS.md 第 6a 步 |
| IPv6 三层关闭 + TUN `strict-route` / `dns-hijack` | IPv6 泄漏、多网卡 DNS 旁路 | AGENTS.md 第 2 步 |
| WFP 程序级直连防护 | 精确到 EXE 的非回环直连阻断，规则见 [应用直连过滤.cs](Desktop防护/应用直连过滤.cs) | AGENTS.md 第 6 步，在本机生成 |

### 首次打开会看到的报错

分享包故意不含本机状态文件、指纹和 GUID，导入别人的会失效甚至拦错程序。所以部署没做完时，以下报错属于预期：

| 现象 | 原因 | 何时消失 |
|---|---|---|
| 一键总检：直连防护项 `FAIL` | `应用过滤目标.json` 要在本机按示例生成（真实路径 + 审核 SHA256 + 新 GUID）后再安装 | AGENTS.md 第 6 步完成后 |
| 一键总检：网段阻断项 `FAIL` | `160.79.104.0/23` 防火墙规则还没创建 | 第 6a 步完成后 |
| 一键总检：Claude 三入口一致性项 `FAIL` | Verge 混合端口不是 `43865` | 按根目录 README「端口说明」改端口后 |
| `应用直连防护管理.ps1 -Action Verify` 报「找不到 应用过滤目标.json」 | 该清单是本机产物，不随包分发 | 第 6 步完成后 |
| 同一条命令报 `0x00000005` / 拒绝访问 | 读取 WFP 规则需要管理员权限；拒绝访问不等于没装 | 用管理员开 PowerShell 7 再跑 |

### 图解资料

| 图 | 看什么 |
|---|---|
| [Claude三入口一出口总架构.svg](assets/Claude三入口一出口总架构.svg) | 三个入口各走哪个端口、汇到哪、规则链顺序 |
| [Claude-Desktop三层防护流程.png](assets/Claude-Desktop三层防护流程-2026-09-12.png) | Desktop 的正常流程、启动前拦截、运行中兜底 |
| [Claude专用浏览器与Clash两层架构.png](assets/Claude专用浏览器与Clash两层架构.png) | 专用 Chrome 的路由层和浏览器环境层、登录前验收 |
| [架构讲解.html](说明/架构讲解.html) | 每个配置点的含义、故障定位到哪一层（可交互） |
