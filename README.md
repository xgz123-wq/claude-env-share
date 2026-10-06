# Claude 环境分享版

> 让 **Claude Code**、**Claude Desktop** 与**专用 Chrome** 走同一条干净、固定、不泄漏的出口。
> 出口不通就断网，**绝不偷偷直连**。
>
> 分享版 · 2026-10-01 从一台已稳定运行的 Windows 机器整理 · 已去掉账号别名、出口 IP 与本机状态文件

![总架构图：三个入口，一个出口](docs/配置/Claude环境/assets/Claude三入口一出口总架构.svg)

## 目录

- [两条路径](#两条路径)
- [它解决什么问题](#它解决什么问题)
- [你要准备的东西](#你要准备的东西)
- [兜底策略与流量走向](#兜底策略与流量走向)
- [图解资料](#图解资料)
- [常见问题](#常见问题)
- [首次打开会看到的报错](#首次打开会看到的报错)
- [这套东西包含什么](#这套东西包含什么)
- [目录结构](#目录结构)
- [边界与平台要求](#边界与平台要求)

---

## 两条路径

拿到这个文件夹，你只需要选一条。

| 路径 | 适合谁 | 怎么做 |
|---|---|---|
| **A · 直接部署** | 我只想配好能用，不想研究原理 | 备齐[你要准备的东西](#你要准备的东西)，然后把文件夹当项目打开，对我说「按 AGENTS.md 帮我部署」 |
| **B · 先搞懂** | 我想知道它动了什么，以后能自己排障 | 按下面的顺序读一遍，再走路径 A |

### 路径 B 的阅读顺序

| 顺序 | 读什么 | 读完知道什么 |
|---|---|---|
| 1 | [架构图](docs/配置/Claude环境/assets/Claude三入口一出口总架构.svg) | 三个入口分别走哪个端口、最后汇到哪 |
| 2 | [兜底策略与流量走向](#兜底策略与流量走向) | 规则怎么匹配、出故障会怎样 |
| 3 | [说明/架构讲解.html](docs/配置/Claude环境/说明/架构讲解.html) | 每个配置点的含义，出问题定位到哪一层（图解，双击打开） |
| 4 | [说明/DNS分层说明.md](docs/配置/Claude环境/说明/DNS分层说明.md) | 为什么 IPv6 要关三层、DNS 怎么分层 |
| 5 | [说明/账号浏览器.md](docs/配置/Claude环境/说明/账号浏览器.md) | 专用 Chrome 的每个启动参数在干什么（配合 [两层架构图](docs/配置/Claude环境/assets/Claude专用浏览器与Clash两层架构.png) 看） |
| 6 | [说明/日常使用.md](docs/配置/Claude环境/说明/日常使用.md) | 每天开工前点什么、看到 FAIL 怎么办 |

---

## 它解决什么问题

一句话：**让 Claude 相关程序走一条干净、固定、不泄漏的出口；出问题时宁可断网，也绝不偷偷直连。**

要同时满足三件事，缺一件就可能被拦或本身有泄漏风险：

| 要做到 | 不这么做会怎样 |
|---|---|
| 出口 IP 干净（住宅、非机房） | Claude 判定为高风险，登录或对话被拦 |
| 出口固定不变 | 同一会话里 IP 在中美之间跳，风控直接判异常 |
| 不泄漏（DNS / IPv6 / WebRTC 都不走本地） | 被检测到本地运营商 DNS 或真实 IP，等于没走代理 |

这套配置就是把上面三件事，在 Clash、Windows 系统、三个程序（CLI / 专用 Chrome / Desktop）上逐层落实。你不需要懂它，照做就行。

---

## 你要准备的东西

### 需要你准备

- [ ] **一台 Windows 10 / 11**，已安装 PowerShell 7（命令是 `pwsh`）
- [ ] **一份你自己的代理订阅**，能在 Clash Verge Rev 里导入
- [ ] **Google Chrome**（只有当你要建专用浏览器时才需要）
- [ ] **你的 Claude 账号**

### 需要你亲手做（AI 替不了）

- [ ] 导入订阅到 Clash Verge Rev
- [ ] 在 `ACCOUNT-US` 组里**手选一个节点** —— 节点质量要你自己判断
- [ ] 弹 UAC 时点「是」 —— 安装直连防护、写系统策略需要管理员权限
- [ ] 登录 Claude 账号
- [ ] 一键总检后**肉眼看检测站** —— 出口、DNS、WebRTC、IPv6、语言、时区要人眼确认

### 然后交给我

把整个文件夹当项目用编辑器打开（Claude Code、Claude Desktop 的 Code 标签页、Codex 都行），说一句：

```text
按 AGENTS.md 帮我在这台机器上部署 Claude 环境
```

我会一步步做，每步先说明要改什么，再动手。

---

## 兜底策略与流量走向

### 三个入口，一个出口

| 入口 | 走哪 | 代理不通时 |
|---|---|---|
| Claude Code CLI / VS Code 插件 | `43865`（Clash 混合端口） | 请求直接失败，不会直连 |
| 专用 Chrome | `43866`（SOCKS） | 页面报代理连接失败，不会直连 |
| Claude Desktop | `43867`（HTTP，HKLM 策略写死） | 网络功能失效，不会直连 |

**最重要的一条：不自动降级。** `ACCOUNT-US` 是 `select` 类型，节点挂了它就停在那里失败，**不会**自动换节点，更不会退回直连。所以哪天突然上不去，先看 Verge 里 `ACCOUNT-US` 选的节点是否还活着。

这条原则落到 Desktop 上的完整流程（正常 / 启动前拦截 / 运行中兜底）见 [Claude-Desktop三层防护流程.png](docs/配置/Claude环境/assets/Claude-Desktop三层防护流程-2026-09-12.png)。

### 规则匹配顺序

规则从上往下匹配，命中即停：

| 顺序 | 规则 | 作用 |
|---|---|---|
| 1 | `IN-NAME,account-us-socks,ACCOUNT-US` | 从 `43866` 进来的连接直接入组 |
| 2 | Claude 域名 / IP 段 / ASN | Claude 流量入组，优先于后面所有规则 |
| 3 | 浏览器 DoH 端点 → `DIRECT` | 防浏览器自带加密 DNS 被兜底规则送出国，把国内域名解析成海外 IP |
| 4 | 订阅原有规则（`GEOSITE,cn` / `GEOIP,CN` → `DIRECT` 等） | 国内流量直连，不绕美国 |
| 5 | `MATCH,Proxy` | 其余走订阅兜底组 |

### 系统层的三道硬拦

与规则无关，独立生效：

| 层 | 拦什么 | 状态 |
|---|---|---|
| 防火墙规则 | 出站阻断 `160.79.104.0/23`，任何程序直连 Anthropic 官方 IP 都被拦 | 部署时创建 |
| IPv6 三层关闭 + TUN `strict-route` / `dns-hijack` | IPv6 泄漏、多网卡 DNS 旁路 | 部署时配置 |
| WFP 程序级直连防护 | 精确到 EXE 的非回环直连阻断（见 [常见问题](#常见问题)） | 需在本机自建 |

### 怎么确认真的走对了

配置写对了**不等于**流量真的走对了。看现场证据：

```powershell
# 五项自检：规则、监听、快捷方式参数、IPv6、真实出口
pwsh -NoProfile -File docs\配置\Claude环境\Clash\Claude日常五项自检.ps1 -Alias 账号1 -NoBrowser

# 全量总检：Clash、DNS、三入口一致、Desktop 代理、直连防护、国内连通
pwsh -NoProfile -File docs\配置\Claude环境\Claude环境一键总检.ps1
```

再打开 Clash Verge 的「连接」页搜 `anthropic`，看命中的是不是 `ACCOUNT-US`。

---

## 图解资料

四张图分工不同，按需要的粒度挑着看：

| 图 | 看什么 | 粒度 |
|---|---|---|
| [Claude三入口一出口总架构.svg](docs/配置/Claude环境/assets/Claude三入口一出口总架构.svg) | 三个入口分别走哪个端口、最终汇到哪、规则链顺序 | 全局 |
| [Claude-Desktop三层防护流程.png](docs/配置/Claude环境/assets/Claude-Desktop三层防护流程-2026-09-12.png) | Desktop 的正常流程、启动前拦截、运行中兜底 | Desktop |
| [Claude专用浏览器与Clash两层架构.png](docs/配置/Claude环境/assets/Claude专用浏览器与Clash两层架构.png) | 专用 Chrome 的路由层 + 浏览器环境层（账号隔离、DNS/WebRTC/IPv6/语言/时区/位置权限）、登录前验收 | 专用 Chrome |
| [架构讲解.html](docs/配置/Claude环境/说明/架构讲解.html) | 每个配置点的含义、故障定位到哪一层 | 全部（可交互，双击打开） |

- 前两张 PNG 是 2026-09 整理时从原机器带过来的参考图，**讲的是局部**，粒度比总架构图细。
- 总架构图覆盖三个入口，PNG 分别只覆盖 Desktop 和专用 Chrome，**内容互补，不重复**。
- 需要文字版对照（谁拦什么、状态如何）看上面[系统层的三道硬拦](#系统层的三道硬拦)。

---

## 常见问题

<details>
<summary><b>要我自己手动配吗？</b></summary>

不用。把文件夹当项目打开，对我说「按 AGENTS.md 帮我部署」，我一步步做。只有[需要你亲手做](#需要你亲手做ai-替不了)的那几件我替不了。
</details>

<details>
<summary><b>需要一直开着 Clash 吗？</b></summary>

需要。它是唯一出口。关了三个入口全断——这是设计如此，不会绕过。
</details>

<details>
<summary><b>上不去 Claude 了，先查什么？</b></summary>

1. Verge 里 `ACCOUNT-US` 选的节点是否还可用
2. Clash 是否在运行、TUN 是否开着

配置写对了不会导致突然不通，多半是节点或 Clash 停了。
</details>

<details>
<summary><b>国内网站会走代理吗？</b></summary>

不会。`GEOSITE,cn` / `GEOIP,CN` 命中即直连；Claude 规则只是排在它们前面。
</details>

<details>
<summary><b>会偷偷直连、暴露真实 IP 吗？</b></summary>

不会。三个入口的代理都是写死的，不通就失败。
</details>

<details>
<summary><b>默认桌面那个 Chrome 快捷方式为什么没参数？</b></summary>

它是日常浏览器。加了参数会把所有流量送去美国、账号隔离也会失效。要用专用浏览器就从「专用 Chrome」快捷方式进。
</details>

<details>
<summary><b>换节点 / 换订阅要重配吗？</b></summary>

都不用改任何配置。

- **换节点**：在 Verge「代理」页里给 `ACCOUNT-US` 重新手选一个即可。
- **换订阅**：Claude 的专用组、置顶规则和两个端口都写在 Clash 的**全局扩展脚本**里，跟订阅解耦，导入新订阅后脚本一行不用改。你只需回到 `ACCOUNT-US` **手选一个节点**（自动填充不会自动选中），再跑一次五项自检 / 一键总检确认出口没变。

本套**不需要**任何「订阅级 rules 覆写」，也没有要你在订阅侧补的东西。
</details>

<details>
<summary><b>一个专用浏览器能登几个账号？</b></summary>

一个。多账号就多建几个专用浏览器。别用 Chrome 自带「添加用户」——它在同一个数据目录里多开 Profile，达不到隔离。
</details>

<details>
<summary><b>什么是「直连防护（WFP）」？</b></summary>

WFP 是 Windows 内核自带的网络过滤框架（Windows 防火墙本身就建在它上面）。这套配置用它给指定 EXE 加规则：**只能走本机回环（也就是代理），想自己连外网就被内核拦掉**。

和防火墙规则的区别：防火墙规则拦的是「目标 IP 段」，WFP 拦的是「发起程序」。所以 WFP 更严——它不管你要连哪，只要是绕开代理的直接出站就拦。

规则原文见 [Desktop防护/应用直连过滤.cs](docs/配置/Claude环境/Desktop防护/应用直连过滤.cs)：`Exact EXE AND not IS_LOOPBACK`，IPv4 / IPv6 各一条。

程序路径、文件哈希、GUID 每台机器都不同，所以分享包里只有一个示例文件，要在本机生成。
</details>

---

## 首次打开会看到的报错

这个分享包**故意不含**本机的状态文件、指纹和 GUID —— 导入别人的会失效，甚至拦错程序。所以刚拿到手时会有几项检查报错，做完对应步骤就消失：

| 现象 | 原因 | 何时消失 |
|---|---|---|
| 一键总检：直连防护项 `FAIL` | `应用过滤目标.json` 要在本机按示例生成（真实路径 + 审核 SHA256 + 新 GUID）后再安装 | 完成部署第 6 步 |
| 一键总检：网段阻断项 `FAIL` | `160.79.104.0/23` 防火墙规则还没创建 | 完成第 6a 步 |
| Skill 自检：快捷方式备份项 `WARN` | 还没把桌面快捷方式复制进 Skill 的 `assets/shortcuts/` | 完成第 7 步 |
| 跑 `应用直连防护管理.ps1 -Action Verify` 报「找不到 应用过滤目标.json」 | 同上，该清单是本机产物，不随包分发 | 完成第 6 步 |
| 跑上面这条报 `0x00000005` / 拒绝访问 | 读取 WFP 规则需要管理员权限。**「拒绝访问」不等于「没装」**，只是没权限看 | 用管理员开 PowerShell 7 再跑 |

这些报错**不代表环境坏了**，只代表「这一步还没做」。

---

## 这套东西包含什么

| 层 | 做什么 | 位置 |
|---|---|---|
| Clash | Claude 域名固定走 `ACCOUNT-US`；三个专用端口 `43865` / `43866` / `43867`；DNS 分层 | [Clash/](docs/配置/Claude环境/Clash/) |
| 系统 | IPv6 三层关闭；TUN 开、系统代理关；`160.79.104.0/23` 直连出站阻断；关定位、杀软白名单 | [说明/DNS分层说明.md](docs/配置/Claude环境/说明/DNS分层说明.md)、[说明/Anthropic网段直连阻断.md](docs/配置/Claude环境/说明/Anthropic网段直连阻断.md) |
| Claude Code | `~/.claude/settings.json` 的 `env` 指向 `43865` | Skill `claude-safe-network` |
| 专用 Chrome | 每个账号独立用户目录，SOCKS `43866`，防 DNS / WebRTC 泄漏 | [说明/账号浏览器.md](docs/配置/Claude环境/说明/账号浏览器.md) |
| Claude Desktop | HKLM 策略走 `43867`、关自动更新、直连防护（WFP） | [Desktop防护/](docs/配置/Claude环境/Desktop防护/) |
| 检查 | 一键总检、五项自检、9 层全量体检 | [Claude环境一键总检.ps1](docs/配置/Claude环境/Claude环境一键总检.ps1) + Skill `scripts/checks/` |

---

## 目录结构

```text
Claude环境分享版/
├─ AGENTS.md                        给 AI 的部署流程和维护约束
├─ CLAUDE.md                        一行 @AGENTS.md，让 Claude 读同一份约定
├─ README.md                        本文件
├─ docs/配置/Claude环境/            日常使用的脚本和说明（部署后桌面图标指向这里）
│  ├─ Claude环境一键总检.ps1        只读总检
│  ├─ Anthropic网段直连阻断.ps1      检查或安装 160.79.104.0/23 出站阻断
│  ├─ 启动Claude英文浏览器.ps1        检查通过才启动 Desktop
│  ├─ 清理维护残留.ps1               列出并清理过期备份；默认只列不删
│  ├─ 维护日志.md                    最近一轮维护的结论与证据
│  ├─ Clash/                        全局脚本副本、通道验证、五项自检
│  ├─ Desktop防护/                  直连防护、43867 通道、自动更新开关
│  ├─ assets/                       图解资料与图标（总架构图 + 两张参考 PNG）
│  └─ 说明/                         架构讲解.html 及四份说明
└─ .agents/skills/
   ├─ claude-safe-network/          安装、检查、排障、回滚工具（含一键更新）
   └─ claude-maintenance/           Desktop / CLI 更新流程
```

---

## 边界与平台要求

| 项 | 说明 |
|---|---|
| **只保证** | 出口干净、不泄漏、不绕过代理 |
| **不做** | 规避检测、伪装身份、绕过 Anthropic 的地区或账号规则；使用前请确认你所在地区和付款方式符合 Anthropic 条款 |
| **平台** | Windows 10 / 11 + Clash Verge Rev（mihomo 内核）+ PowerShell 7，仅此三种 |
