# Clash DNS 分层说明

> 整理日期：2026-11-07
> 用途：说明网络分工与维护边界
> 端口：文中 43865 / 43866 / 43867 是默认值，本机以部署清单为准，见 [README「部署清单」](../README.md#部署清单)。

## 网络分工

- **普通应用**：国内流量按规则直连，国外流量按订阅规则分流。
- **Claude 域名**：使用独立解析规则，连接沿既有 `ACCOUNT-US` 通道。
- **普通 DNS**：Clash Verge 的 DNS 覆写 `dns_config.yaml` 优先于订阅；它的 `nameserver` 只放海外 DoH（`https://8.8.8.8/dns-query`、`https://1.1.1.1/dns-query`）。
- **国内域名 DNS**：靠订阅带来的 `geosite:cn,private` 策略问国内 DNS；换订阅后要确认运行配置 `clash-verge.yaml` 里还有这条策略。
- **判断原则**：国内网站解析到国内地址，本身不代表 DNS 泄漏。

## 普通浏览器防 DNS 泄露

**结论**：在 Clash 修，不在浏览器加参数；`nameserver` 不放国内 DNS。

| 项目 | 做法 | 原因 |
|---|---|---|
| Clash `nameserver` | 不放 `doh.pub`、`dns.alidns.com` 这类国内 DNS | `GEOIP,CN,DIRECT` 没带 `no-resolve`，域名走到这条规则时 Clash 要先查一次 DNS；列表里有国内 DNS，海外域名也会问到它，`doh.pub` 实测走 `DIRECT`，检测站报泄露（2026-11-07 修复） |
| 普通 Chrome 启动参数 | 不加专用 Chrome 的 `--host-resolver-rules` | 这个参数把浏览器本地解析全部关掉，离开 `--proxy-server` 就上不了网；系统 DNS 已由 TUN 接管 |
| 浏览器安全 DNS | 保持关闭 | 浏览器自己解析会绕过 TUN 的 53 劫持，按域名分流的规则容易失准 |

- **影响范围**：`nameserver` 是 Clash 全局设置，全机软件都生效；Claude 域名和国内域名有各自的策略，不受它影响。
- **边界**：不在国内域名库里的小众国内网站会问海外 DNS，可能变慢或打不开。

## IPv6 三层关闭

| 层 | 操作位置 | 现状（2026-09-23 核对） |
|---|---|---|
| 网卡 | 控制面板 → 网络和 Internet → 网络连接 → 网卡属性 → 取消勾选「Internet 协议版本 6 (TCP/IPv6)」 | WLAN、VMnet1、VMnet8 已关；`Mihomo`（TUN 虚拟网卡）保持开启，属正常 |
| Clash 全局 | Clash Verge 设置里的 IPv6 开关 | `config.yaml`、`clash-verge.yaml` 为 `ipv6: false` |
| Clash DNS 覆写 | DNS 覆写里的 IPv6 开关 | `dns_config.yaml` 为 `ipv6: false` |

- **命令等价操作**（管理员）：`Disable-NetAdapterBinding -Name 'WLAN' -ComponentID ms_tcpip6`；查看用 `Get-NetAdapterBinding -ComponentID ms_tcpip6`。
- **作用范围**：按网卡生效，同一张网卡换 Wi-Fi 不用重做；新增网卡（USB 网卡、新无线网卡）要重新取消勾选。
- **自动检查**：环境卫士 S4「IPv6 防漏」检查公网 IPv6 地址和 `DisabledComponents`，并实测能否直连 IPv6。
- **现状结论**：本机没有公网 IPv6 地址，也没有 IPv6 默认路由。

## 维护与验收

- **现场优先**：以当前生效脚本、运行配置及实际连接为准。
- **禁止盲同步**：不得用本目录或技能内的旧脚本直接覆盖现场 `Script.js`。
- **变更顺序**：先比对差异，再备份，仅修改已确认的问题。
- **核验内容**：运行模式、监听、规则命中及真实出口。
- **网页边界**：普通浏览器检测结果不能替代 Claude 专用浏览器验收。

## Claude 域名定期复核

**结论**：后台出口巡检每天自动跑一次 `Clash/检查Claude官方域名.ps1`，有未归类新域名就弹窗（见[日常使用「后台出口巡检」](日常使用.md#后台出口巡检)）；Desktop、CLI、浏览器、插件更新后再手动对照 [Anthropic Desktop 网络要求](https://code.claude.com/docs/en/desktop#network-access-requirements)和 [Claude Code 网络要求](https://code.claude.com/docs/en/network-config#network-access-requirements)复核域名；订阅、节点、Clash 规则变化或登录、下载、桥接异常时也复核。官方列表是来源，实际连接和 Mihomo 命中是现场证据。

| 入口 | 新域名如何进入 `ACCOUNT-US` | 复核重点 |
|---|---|---|
| CLI `43865` | 共用入口按置顶 Claude 域名规则分流 | 新域名、命中规则、DNS policy、最终策略组与出口 |
| 专用 Chrome `43866` | 专用 SOCKS listener 直接指定 `ACCOUNT-US`（2026-11-11 起，切全局、直连模式都不变），置顶 `IN-NAME` 规则保留 | 实际浏览器连接是否进入 `43866`，以及网页出口、DNS、WebRTC |
| Desktop `43867` | 进入专用 HTTP listener 的连接指定 `ACCOUNT-US` | Desktop 与子进程的真实连接是否进入 `43867` |

**分工**：官方清单比对由脚本 `Clash/检查Claude官方域名.ps1` 完成，只有脚本报出未归类新域名时才需要模型判断。

| 步骤 | 谁做 | 说明 |
|---|---|---|
| 抓官方两份文档、提取域名、按后缀归类 | 脚本（只读，只 GET 官方 Markdown） | 退出码 `0` 全部已归类，保持安静；`1` 有未归类新域名；`2` 抓取或解析失败 |
| 判断新域名是 Claude 专属还是共享第三方 | 模型 | 看官方用途说明；共享的写入脚本内 `$sharedHosts` 并写明原因，专属的走变更流程加规则 |
| 改规则、复制到现场 `Script.js` | 用户确认后由 AI 做 | 只改 `Clash全局账号通道.js` 的规则清单 |
| 重载 Clash | 用户 | AI 不重启 Clash 或 Claude，也不热重载 |
| 核对现场规则、运行配置、验证脚本有没有遗漏或漂移 | 模型（只读） | 结论与建议写给用户 |
| 真实浏览器网页验收、Desktop 内置浏览器验收 | 用户 | 未观察到的访问只记为规则覆盖，不记为实测通过 |

**归类规则**：被 `Clash全局账号通道.js` 里 Claude 域名后缀或精确域名规则覆盖的记为已覆盖，如 `platform.claude.com`、`downloads.claude.ai`、`bridge.claudeusercontent.com`、`http-intake.logs.us5.datadoghq.com`；在 `$sharedHosts` 里的记为共享，如 npm、GitHub、Google Storage、`browser-intake-us5-datadoghq.com`、字体与脚本 CDN；其余都是未归类。共享域名不全局绑定 `ACCOUNT-US`。

**运行**：`pwsh -NoProfile -File docs\配置\Claude环境\Clash\检查Claude官方域名.ps1`，输出 JSON；`-OfflineDir <目录>` 可用已下载的 `network-config.md`、`desktop.md` 离线测试。

**新增域名后**：用户重载后跑总检，它按内核实际加载的规则核对内容和顺序；再用 `Clash/查域名走哪条规则.ps1 <域名>` 实测命中。完整流程见 [入口页「外部信息」](架构讲解.html#external)。

**规则来源**：Anthropic Desktop 网络要求列出 `claude.app` 及动态子域，因此本分享版的规则模板包含 `DOMAIN-SUFFIX,claude.app` 与 `+.claude.app`；部署后的实际访问和出口要在使用者机器上验证。CLI 官方清单未把它列为独立的 CLI 必需域名。

**2026-11-05 范围**：置顶规则增加三项，都不加 DNS policy（规则按域名或 IP 直接命中，不需要先解析）。

| 规则 | 原因 | 边界 |
|---|---|---|
| `DOMAIN,http-intake.logs.us5.datadoghq.com` | 官方清单点名的 Datadog 接收地址 | 只写完整域名；`keyword:datadog`、`+.datadoghq.com`、`browser-intake-us5-datadoghq.com` 仍不入组，验证脚本继续禁止 |
| `GEOSITE,anthropic` | 补上后缀规则之外的 Anthropic 域名，如 `claude.site`、`claude.dev` | 内容随 geosite 每日更新，不归本项目控制；原有后缀规则保留 |
| `IP-CIDR,153.61.224.0/22` | 官方 IP 文档新列的接收网段；本地 ASN 库查不到它，`IP-ASN` 兜不住 | 只影响直接连 IP 的流量，走域名的连接先命中域名规则 |

同日基线整理删除 `DOMAIN,servd-anthropic-website.b-cdn.net`：它已被 `GEOSITE,anthropic` 完全覆盖。

## 文件与阅读入口

| 材料 | 作用 |
|---|---|
| [架构讲解](架构讲解.html) | 统一入口，先读 |
| `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\Script.js` | 需现场核对的 Clash 全局脚本 |
| `../Clash/Clash全局账号通道.js` | 项目副本（唯一一份）；维护前先与现场 `Script.js` 比较哈希 |
