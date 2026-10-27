# Claude 环境：部署与维护约定

> 给 Claude Code / Codex 等读取 AGENTS.md 的工具使用。
> 本目录是分享版：原机器的账号别名、出口 IP、状态文件已去掉；README 里标「参考值」的版本号以本机实测为准。

## 入口

| 要做什么 | 入口 |
|---|---|
| 了解整体、给用户解释 | `README.md`；图解给用户看 `docs/配置/Claude环境/说明/架构讲解.html` |
| 目录、代理路线 | `docs/配置/Claude环境/README.md` |
| 排障说明（命令指回 docs） | `.agents/skills/claude-safe-network/SKILL.md` |
| 安装、回滚等一次性工具 | `docs/配置/Claude环境/工具/` |
| 部署后的 Desktop / CLI 更新 | `.agents/skills/claude-maintenance/SKILL.md` |

## 首次部署（新机器）

按顺序做，每步先向用户说明要改什么，确认后再执行；每个脚本先读文件头部说明，有只读 / 预览模式的先跑只读模式。

| 步骤 | 做什么 | 依据 |
|---|---|---|
| 0 前置 | 确认 Windows 10/11、PowerShell 7、Clash Verge Rev、Chrome、Claude Code、Claude Desktop 已安装；用户已导入订阅 | `README.md`「适用条件」 |
| 0a 端口预检 | 读 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\verge.yaml` 的 `verge_mixed_port`，不是 `43865` 就请用户在 Verge「设置 → Clash 设置 → 端口设置」里改成 `43865`，不要改脚本去迁就；再查 `43866` / `43867` 是否已被非 `verge-mihomo` 的程序监听，有就停下告诉用户。只读这一个字段，不读 `profiles.yaml` | `README.md`「端口说明」 |
| 1 Clash | 把 `docs/配置/Claude环境/Clash/Clash全局账号通道.js` 装为 Verge 全局扩展脚本；开 TUN、关系统代理；请用户在 `ACCOUNT-US` 手选节点 | `docs/配置/Claude环境/工具/安装Clash账号专用通道.ps1`、Skill `references/01-架构与配置主体.md` |
| 2 IPv6 与 DNS | 网卡、Clash 全局、Clash DNS 覆写三层关闭 IPv6 | `docs/配置/Claude环境/说明/DNS分层说明.md` |
| 3 Claude Code | `~/.claude/settings.json` 的 `env` 设 `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` 为 `http://127.0.0.1:43865`，`NO_PROXY` 为 `localhost,127.0.0.1,*.local`；只改 `env`，不动其他字段 | Skill `SKILL.md` |
| 4 专用 Chrome | 每个账号建独立浏览器：`创建账号浏览器.ps1 -Alias 账号1`（别名由用户定） | `docs/配置/Claude环境/工具/创建账号浏览器.ps1`、`docs/配置/Claude环境/说明/账号浏览器.md` |
| 5 Desktop 通道 | `Desktop防护/专用通道管理.ps1 -Action Install`（43867 与 HKLM `egressProxyUrl`）；`Claude自动更新管理.ps1 -Action Disable` | `docs/配置/Claude环境/Desktop防护/更新维护说明.md` |
| 6 直连防护 | 按 `应用过滤目标.示例.json` 生成本机 `应用过滤目标.json`：填本机真实路径，SHA256 审核后填写，GUID 新生成；再 `应用直连防护管理.ps1 -Action Install`（管理员） | 同上 |
| 6a 网段阻断 | 以管理员运行 `pwsh -File docs/配置/Claude环境/Anthropic网段直连阻断.ps1 -Action Install`，阻断 `160.79.104.0/23` 的直接出站；再用默认只读模式核对 | `docs/配置/Claude环境/说明/Anthropic网段直连阻断.md` |
| 7 快捷方式 | 桌面建「Claude-环境一键总检」「Claude-英文浏览器」「Claude-三端更新」，目标为 PowerShell 7 加 `-File` 指向对应 docs 脚本；各账号 Chrome 快捷方式第 4 步已建 | `docs/配置/Claude环境/说明/日常使用.md`「桌面入口与维护」 |
| 8 验收 | 一键总检 0 FAIL；`docs/配置/Claude环境/工具/检查脚本完整性.ps1` 0 FAIL；用户肉眼核对检测站；把结果写进 `维护日志.md` | `docs/配置/Claude环境/Claude环境一键总检.ps1` |
| 9 部署清单 | 最后再跑一次一键总检（顺带生成清单）：它从 Clash 运行配置读出三个端口、登记桌面上的专用浏览器，写进 `%LOCALAPPDATA%\ClaudeNetworkGuard\部署清单.json`；确认三个端口与 Clash 一致、每个专用浏览器都已登记。之后改端口只在 Clash 改，再跑一次总检 | `docs/配置/Claude环境/README.md`「部署清单」 |

- **分享版的已知问题**：步骤 6 之前，`工具/检查脚本完整性.ps1` 的防护状态项报 WARN；步骤 7 之前，它的桌面图标项报 WARN；步骤 6 之前，总检的直连防护项报 FAIL；步骤 6a 之前，网段阻断项报 FAIL。都属预期，做完对应步骤后消失。

## 推荐安装目录

| 情况 | 位置 |
|---|---|
| 有 D 盘 | `D:\Tools\Claude环境\`：放环境卫士两个 exe 和本分享包（git clone） |
| 没有 D 盘 | `%LOCALAPPDATA%\Programs\Claude环境\` |
| 专用浏览器数据 | 不随安装目录走，固定在 `%LOCALAPPDATA%\ClaudeAccountBrowsers\` |

- **分享包放哪都行**：一键总检会把自己的位置写进部署清单，环境卫士按清单找，不用放桌面；目录层级不能变（总检按「脚本目录往上 3 层 = 项目根」定位）。

## 维护工作流程（部署后）

1. **先读现状**：`docs/配置/Claude环境/README.md` → `维护日志.md` 末尾 → 对应 Skill。
2. **改前备份**：改动文件复制到 `%LOCALAPPDATA%\ClaudeNetworkGuard\<中文任务名>-<yyyyMMdd-HHmmss>\`。
3. **改后验证**：一键总检 0 FAIL；动了脚本或文档再跑 `docs/配置/Claude环境/工具/检查脚本完整性.ps1`。
4. **记录**：`维护日志.md` 只保留最近一轮的完整一节，上一轮压成「历史」表一行，不新建记录文件。
5. **清理**：收尾跑 `docs/配置/Claude环境/清理维护残留.ps1`（默认只列清单），列给用户确认后加 `-Yes` 删除。

## 约束

- **先查网关**：`~/.claude/settings.json` 的 `env` 若有 `ANTHROPIC_BASE_URL` 指向第三方网关，Claude 域名规则对 Claude Code 不生效，先向用户说明再继续。
- **订阅链接是高危信息**：部分订阅 URL 参数是 base64 编码的节点密钥；排查中不要打印，若已打印提醒用户不要外发终端记录。
- **不代替用户**：不选节点、不登录账号、不读或输出订阅链接、节点密钥、Cookie、token。
- **默认不启动**：Claude Desktop、Claude Code、浏览器；一键总检带 `-OpenBrowser` 会打开日常专用 Chrome（默认 `Claude-账号1-专用Chrome.lnk`，用 `-DailyBrowser` 换），先告知。
- **目录层级不能变**：总检按「脚本目录往上 3 层 = 项目根」定位。
- **docs 是唯一来源**：脚本、配置和防护状态 json 只在 `docs/配置/Claude环境/`；Skill 只放说明，命令指回 docs，不要在 Skill 里放脚本副本。
- **不导入别人的状态**：防护状态 json、指纹、GUID 必须在本机生成。
- **会话代理**：若会话环境被注入 `HTTPS_PROXY=http://127.0.0.1:43867`，访问国内站点前用 `env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY` 去掉代理变量，不要为此改 Clash。

## 部署清单的三条规矩

端口和路径记在部署清单 `%LOCALAPPDATA%\ClaudeNetworkGuard\部署清单.json`，说明见 `docs/配置/Claude环境/README.md`「部署清单」。

| 规矩 | 意思 |
|---|---|
| 同一个值只存一处 | 端口、路径只在清单里有数字（源头是 Clash）；脚本用 `Get-DeployPort` 按名字取，环境卫士按名字读，不再写死 |
| 写的和查的分开 | 分享包脚本写清单（一键总检刷新、建浏览器登记）、按清单抄写配置；环境卫士只读清单和对账，不改清单 |
| 第三次出现就收进清单 | 新功能要用某个值时，如果已经有两处在用，先加进清单和 `读部署清单.ps1`，再用 |

## 文档规范

- 结论和操作先写；每行一个事实；成对信息用表格；bullet 用加粗字段名开头。
- 相同事实只在一个位置维护；区分当前状态、历史证据、未验证事项。
