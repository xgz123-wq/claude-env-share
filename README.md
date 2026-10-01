# Claude 环境分享版

> **版本**：2026-10-01，从一台已稳定运行的 Windows 机器整理而来
> **用途**：让另一台 Windows 机器照着部署一套「Claude Code + Claude Desktop + 专用 Chrome 走同一个干净出口」的环境
> **个人信息**：账号别名、出口 IP、本机状态文件已去掉；版本号、路径等标为「原机器参考值」的内容以你自己的实测为准

## 怎么用

1. **先看图解**：双击 `docs/配置/Claude环境/说明/架构讲解.html`，弄清三个入口、Clash、DNS 与 IPv6、系统设置，以及出问题去哪改。
2. **把整个文件夹当项目打开**：Claude Code、Claude Desktop 的 Code 标签页或 Codex 都行，AI 会自动读 `AGENTS.md`。
3. **对 AI 说**：「按 AGENTS.md 帮我在这台机器上部署 Claude 环境」。它会一步步做，每步先说明再动手。
4. **下面这些要你自己做**（AI 替不了）：

| 事项 | 为什么 |
|---|---|
| 准备订阅，导入 Clash Verge Rev | 订阅是你自己的 |
| 在 `ACCOUNT-US` 组里手选节点 | 节点质量要你判断 |
| 点 UAC「是」 | 安装直连防护、写系统策略需要管理员 |
| 登录 Claude 账号 | 账号不能拷贝 |
| 一键总检后肉眼看检测站 | 出口、DNS、WebRTC、IPv6、语言、时区要人眼确认 |

## 这套东西包含什么

| 层 | 做什么 | 位置 |
|---|---|---|
| Clash | Claude 域名固定走 `ACCOUNT-US`；三个专用端口 `43865` / `43866` / `43867`；DNS 分层 | `docs/配置/Claude环境/Clash/` |
| 系统 | IPv6 三层关闭；TUN 开、系统代理关；`160.79.104.0/23` 直连出站阻断；关定位、杀软白名单 | `说明/DNS分层说明.md`、`说明/Anthropic网段直连阻断.md`、`说明/架构讲解.html` 第七步 |
| Claude Code | `~/.claude/settings.json` 的 `env` 指向 `43865` | Skill `claude-safe-network` |
| 专用 Chrome | 每个账号独立用户目录，SOCKS `43866`，防 DNS / WebRTC 泄漏 | `docs/配置/Claude环境/说明/账号浏览器.md` |
| Claude Desktop | HKLM 策略走 `43867`、关自动更新、直连防护（WFP） | `docs/配置/Claude环境/Desktop防护/` |
| 检查 | 一键总检、五项自检、9 层全量体检 | 根目录脚本 + Skill `scripts/checks/` |

## 目录

| 位置 | 内容 |
|---|---|
| `AGENTS.md` | 给 AI 的部署流程和维护约束 |
| `CLAUDE.md` | 一行 `@AGENTS.md`，让 Claude 读同一份约定 |
| `docs/配置/Claude环境/说明/架构讲解.html` | 图解讲解：架构、每个配置点的含义、故障定位 |
| `docs/配置/Claude环境/` | 日常使用的脚本和说明（部署后桌面图标指向这里） |
| `.agents/skills/claude-safe-network/` | 安装、检查、排障、回滚工具和手册（隐藏目录） |
| `.agents/skills/claude-maintenance/` | Desktop / CLI 更新流程 |

## 边界

- **只保证**：出口干净、不泄漏、不绕过代理。
- **不做**：规避检测、伪装身份、绕过 Anthropic 的地区或账号规则；使用前确认你所在地区和付款方式符合 Anthropic 条款。
- **平台**：只支持 Windows 10 / 11 + Clash Verge Rev（mihomo 内核）+ PowerShell 7。
