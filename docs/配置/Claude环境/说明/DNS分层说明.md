# Clash DNS 分层说明

> 整理日期：2026-09-23
> 用途：说明网络分工与维护边界

## 网络分工

- **普通应用**：国内流量按规则直连，国外流量按订阅规则分流。
- **Claude 域名**：使用独立解析规则，连接沿既有 `ACCOUNT-US` 通道。
- **普通 DNS**：沿用当前合并配置的通用解析器。
- **判断原则**：国内网站解析到国内地址，本身不代表 DNS 泄漏。

## IPv6 三层关闭

| 层 | 操作位置 | 现状（2026-09-23 核对） |
|---|---|---|
| 网卡 | 控制面板 → 网络和 Internet → 网络连接 → 网卡属性 → 取消勾选「Internet 协议版本 6 (TCP/IPv6)」 | WLAN、VMnet1、VMnet8 已关；`Mihomo`（TUN 虚拟网卡）保持开启，属正常 |
| Clash 全局 | Clash Verge 设置里的 IPv6 开关 | `config.yaml`、`clash-verge.yaml` 为 `ipv6: false` |
| Clash DNS 覆写 | DNS 覆写里的 IPv6 开关 | `dns_config.yaml` 为 `ipv6: false` |

- **命令等价操作**（管理员）：`Disable-NetAdapterBinding -Name 'WLAN' -ComponentID ms_tcpip6`；查看用 `Get-NetAdapterBinding -ComponentID ms_tcpip6`。
- **作用范围**：按网卡生效，同一张网卡换 Wi-Fi 不用重做；新增网卡（USB 网卡、新无线网卡）要重新取消勾选。
- **自动检查**：五项自检和 Skill `Check-WindowsFallback.ps1` 会检查物理网卡 IPv6 绑定，未关闭时报出。
- **现状结论**：本机没有公网 IPv6 地址，也没有 IPv6 默认路由。

## 维护与验收

- **现场优先**：以当前生效脚本、运行配置及实际连接为准。
- **禁止盲同步**：不得用本目录或技能内的旧脚本直接覆盖现场 `Script.js`。
- **变更顺序**：先比对差异，再备份，仅修改已确认的问题。
- **核验内容**：运行模式、监听、规则命中及真实出口。
- **网页边界**：普通浏览器检测结果不能替代 Claude 专用浏览器验收。

## 文件与阅读入口

| 材料 | 作用 |
|---|---|
| [Claude 配置总览](../README.md) | 统一入口，先读 |
| `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles\Script.js` | 需现场核对的 Clash 全局脚本 |
| `../Clash/Clash全局账号通道.js` | 项目副本；2026-09-23 与现场 `Script.js`、Skill 副本三处哈希一致，维护前仍先比较 |
