// Clash Verge「全局扩展脚本」。现场文件 profiles\Script.js 要与本文件字节一致，改完由用户在 Clash Verge 里重载才生效。
// Claude 规则只在下面「规则清单」一段维护：验证脚本、官方域名复核、架构讲解页都从这里读，不要在别处另抄一份。
function main(config, profileName) {
  var groupName = "ACCOUNT-US";
  var listenerName = "account-us-socks";
  var inboundRule = "IN-NAME," + listenerName + "," + groupName;
  var accountDnsServers = [
    "https://1.1.1.1/dns-query#" + groupName,
    "https://8.8.8.8/dns-query#" + groupName
  ];

  // ===== 规则清单 开始 =====
  // 一行一条，行尾 // 后面写用途；工具\读Claude规则.ps1 按变量名逐行解析，不要改变量名和写法。
  // 后缀：同时生成路由规则和 DNS policy，子域名全部覆盖。Clash 规则页只显示后缀本身，搜 downloads 搜不到是正常的。
  var claudeSuffixes = [
    "anthropic.com",         // API（api.）、MCP 连接器（mcp-proxy.）、Desktop 的 CDN（a-cdn.、assets-proxy. 等）
    "claude.ai",             // 网页和账号登录；downloads.claude.ai 是插件、原生安装和自动更新的下载点
    "claude.com",            // 登录跳转、OAuth（platform.）、单点登录（sso.）、官方文档（code.）
    "claude.app",            // Desktop 官方清单里的 livepreview 预览
    "clau.de",               // 短链；官方网络清单没列，geosite 有
    "claudemcpclient.com",   // MCP 相关；官方网络清单没列，geosite 有
    "claudemcpcontent.com",  // 对话里的 MCP Apps 小组件
    "claudeusercontent.com"  // Claude in Chrome 桥接（bridge.）、Artifact 内容（frame.）
  ];
  // 精确域名：后缀和 geosite 都盖不到的。第三方平台的域名只入组点名的这一个，不扩到整个后缀。
  var claudeExactDomains = [
    "anthropic.com.cdn.cloudflare.net",   // anthropic.com 在 Cloudflare 上的 CNAME；不在 geosite
    "anthropic.auth0.com",                // Anthropic 专属的 Auth0 登录租户；不在 geosite
    "anthropic-com.ghost.io",             // Anthropic 专属的 Ghost 托管；不在 geosite
    "http-intake.logs.us5.datadoghq.com"  // 官方清单点名的运行遥测；其他 Datadog 域名不入组
  ];
  // geosite 分类：第三方库 MetaCubeX 维护，补上面没单列的域名（claude.dev、claude.site、antspace.dev 等）。
  // 分类名写错或库里没有，整份 Clash 配置会加载失败，加新分类前先用内核 -t 校验。
  var claudeGeosites = [
    "anthropic"  // 与后缀有重叠是故意的：主通道不押在第三方库上，后缀还要和 DNS policy 一一对应
  ];
  // IP 规则：一律 no-resolve，不为匹配 IP 规则去解析域名；只有程序直接连 IP 时才命中。
  var claudeIpRules = [
    "IP-CIDR,160.79.104.0/21",   // 官方对外段，含 API 接收段 160.79.104.0/23
    "IP-CIDR,153.61.224.0/22",   // 官方 API 接收段
    "IP-CIDR6,2607:6bc0::/32",   // 官方 IPv6，含 API 接收段 2607:6bc0::/48
    "IP-ASN,399358"              // Anthropic 的自治系统号，兜官方还没列出的新段
  ];
  // 订阅自带的 Claude 规则按这个特征清掉，防止 Claude 被送去别的组。验证脚本用同一个特征查漏网的。
  var claudeIdentity = /anthropic|claude|clau\.de|160\.79\.104\.|153\.61\.224\.|2607:6bc0|399358/i;
  // ===== 规则清单 结束 =====

  function toRules(prefix, items, target) {
    return items.map(function (item) {
      return prefix + item + "," + target;
    });
  }
  var claudeRules = toRules("DOMAIN-SUFFIX,", claudeSuffixes, groupName).concat(
    toRules("DOMAIN,", claudeExactDomains, groupName),
    toRules("GEOSITE,", claudeGeosites, groupName),
    claudeIpRules.map(function (item) {
      return item + "," + groupName + ",no-resolve";
    })
  );

  // 只看「类型,匹配内容」两段，不看目标组名：订阅可能有叫 Claude 的组，指向它的其他规则不该被误删。
  function isClaudeRule(rule) {
    if (typeof rule !== "string") {
      return false;
    }
    return rule === inboundRule || claudeIdentity.test(rule.split(",").slice(0, 2).join(","));
  }

  if (!Array.isArray(config["proxy-groups"])) {
    config["proxy-groups"] = [];
  }
  config["proxy-groups"] = config["proxy-groups"].filter(function (group) {
    return !group || group.name !== groupName;
  });
  config["proxy-groups"].unshift({
    name: groupName,
    type: "select",
    "include-all-proxies": true,
    "exclude-type": "Direct|Reject"
  });

  // 全局模式也只走账号组：切到「全局」时内核不看任何规则，所有流量交给 GLOBAL 组，
  // 内核自带的 GLOBAL 默认选 DIRECT（2026-11-10 误切全局，43865/43866 因此直连）。自定义后只剩 ACCOUNT-US 一个选项。
  config["proxy-groups"] = config["proxy-groups"].filter(function (group) {
    return !group || group.name !== "GLOBAL";
  });
  config["proxy-groups"].push({
    name: "GLOBAL",
    type: "select",
    proxies: [groupName]
  });

  // 只加固 Claude 链路：相关域名使用加密 DNS，且 DoH 连接明确经过 ACCOUNT-US。
  // 普通/国内 DNS 保留订阅与 Clash 的通用解析器，不绑定任何专用代理组。
  if (!config.dns || typeof config.dns !== "object") {
    config.dns = {};
  }
  if (!config.dns["nameserver-policy"] ||
      typeof config.dns["nameserver-policy"] !== "object" ||
      Array.isArray(config.dns["nameserver-policy"])) {
    config.dns["nameserver-policy"] = {};
  }
  // 2026-11-14 按经验帖：走直连的国内域名（和规则同一份 Loyalsoldier direct 名单）由国内 DNS 解析；
  // 原来按 geosite:cn 选国内 DNS 的条目去掉，免得两份名单不一致。局域网域名照旧问国内 DNS。
  // 只改「谁来回答国内域名」，不改任何流量的去向；Claude 后缀排在最前面，仍经 ACCOUNT-US 查。
  var domesticDnsServers = ["223.5.5.5", "119.29.29.29"];
  var oldPolicy = config.dns["nameserver-policy"];
  var newPolicy = {};
  claudeSuffixes.forEach(function (suffix) {
    newPolicy["+." + suffix] = accountDnsServers.slice();
  });
  newPolicy["rule-set:loyalsoldier-direct"] = domesticDnsServers.slice();
  newPolicy["geosite:private"] = domesticDnsServers.slice();
  Object.keys(oldPolicy).forEach(function (key) {
    if (!(key in newPolicy) && !/geosite:[^,]*\bcn\b/i.test(key)) {
      newPolicy[key] = oldPolicy[key];
    }
  });
  config.dns["nameserver-policy"] = newPolicy;

  // 2026-09-11 DNS 分层：不覆盖 nameserver、direct-nameserver 或 fallback。
  // 这样飞书等普通应用的 DNS 不依赖 ACCOUNT-US；Claude 域名仍由上方 policy 加固。
  config.dns.enable = true;

  // Windows 多网卡 DNS 旁路防护：ETW 已确认 WLAN 与 TUN 并行代查。
  config.tun = config.tun || {};
  config.tun["strict-route"] = true;
  config.tun["dns-hijack"] = ["any:53", "tcp://any:53"];

  if (!Array.isArray(config.listeners)) {
    config.listeners = [];
  }
  config.listeners = config.listeners.filter(function (listener) {
    return !listener || listener.name !== listenerName;
  });
  // 专用 Chrome：和 43867 一样直接进账号组，Clash 切到全局、直连都不影响（2026-11-11 起；之前只靠 IN-NAME 规则，切直连模式会漏）。
  // IN-NAME 规则保留，规则页和验证脚本仍按它认这个入口。
  config.listeners.unshift({
    name: listenerName,
    type: "socks",
    listen: "127.0.0.1",
    port: 43866,
    proxy: groupName,
    udp: false
  });

  // Claude Desktop：HTTP 专用入口直接进入账号组，不改变其他应用的 DNS/分流。
  config.listeners = config.listeners.filter(function (listener) {
    return !listener || listener.name !== "claude-desktop-http";
  });
  config.listeners.unshift({
    name: "claude-desktop-http",
    type: "http",
    listen: "127.0.0.1",
    port: 43867,
    proxy: groupName,
    users: []
  });

  if (!Array.isArray(config.rules)) {
    config.rules = [];
  }
  config.rules = config.rules.filter(function (rule) {
    return !isClaudeRule(rule);
  });
  // 2026-11-14 统一海外出口：国内名单直连，其余全部进 ACCOUNT-US（组里没有 DIRECT，节点挂了就断，不换线、不回落直连）。
  // 订阅规则里除 DIRECT / REJECT 以外的目标组（Proxy、自动切换等）一律改指 ACCOUNT-US，订阅改组名也冲不掉。
  var keepTargets = /^(DIRECT|REJECT|REJECT-DROP|PASS)$/i;
  function retarget(rule) {
    if (typeof rule !== "string") {
      return rule;
    }
    var head;
    var rest;
    if (/^(AND|OR|NOT),/i.test(rule)) {
      var cut = rule.lastIndexOf("),");
      if (cut < 0) {
        return rule;
      }
      head = rule.slice(0, cut + 1);
      rest = rule.slice(cut + 2).split(",");
    } else {
      var parts = rule.split(",");
      var headCount = /^MATCH$/i.test(parts[0]) ? 1 : 2;
      if (parts.length <= headCount) {
        return rule;
      }
      head = parts.slice(0, headCount).join(",");
      rest = parts.slice(headCount);
    }
    if (keepTargets.test(rest[0].trim()) || rest[0].trim() === groupName) {
      return rule;
    }
    rest[0] = groupName;
    return head + "," + rest.join(",");
  }
  function ruleKey(rule) {
    return typeof rule === "string" ? rule.replace(/\s+/g, "").toUpperCase() : "";
  }
  // 按经验帖的顺序排：Claude → 局域网 → B 站和微信 → 海外分类 → 国内名单 → 其余全走 ACCOUNT-US。
  // 直连只认这里写的几类：订阅自带的 DIRECT 规则全部清掉，订阅的拦截规则和改指账号组的规则保留在局域网之后。
  var lanRules = [
    "IP-CIDR,127.0.0.0/8", "IP-CIDR,10.0.0.0/8", "IP-CIDR,172.16.0.0/12", "IP-CIDR,192.168.0.0/16",
    "IP-CIDR,100.64.0.0/10", "IP-CIDR,169.254.0.0/16",
    "IP-CIDR6,::1/128", "IP-CIDR6,fc00::/7", "IP-CIDR6,fe80::/10"
  ].map(function (item) {
    return item + ",DIRECT,no-resolve";
  });
  var subscriptionRules = config.rules.map(retarget).filter(function (rule) {
    var key = ruleKey(rule);
    return !/,DIRECT(,|$)/.test(key) && !/^MATCH,/.test(key) && !/^GEOSITE,GEOLOCATION-!CN,/.test(key);
  });
  // 国内名单用 Loyalsoldier/clash-rules 的 direct（国内域名）和 cncidr（国内 IP），每天更新，经账号组下载。
  config["rule-providers"] = config["rule-providers"] || {};
  config["rule-providers"]["loyalsoldier-direct"] = {
    type: "http", behavior: "domain", format: "yaml", interval: 86400, proxy: groupName,
    url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt",
    path: "./ruleset/loyalsoldier-direct.yaml"
  };
  config["rule-providers"]["loyalsoldier-cncidr"] = {
    type: "http", behavior: "ipcidr", format: "yaml", interval: 86400, proxy: groupName,
    url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/cncidr.txt",
    path: "./ruleset/loyalsoldier-cncidr.yaml"
  };
  var domesticRules = [
    "GEOSITE,bilibili,DIRECT",
    "DOMAIN-KEYWORD,mirrorakam,DIRECT",   // B 站视频走 akamaized.net，按后缀匹配不上
    "GEOSITE,tencent,DIRECT",             // 微信（库里没有单独的 wechat 分类）
    // 海外分类必须排在国内名单前面：direct.txt 里混着 googletagmanager、doubleclick 这类海外域名。
    "GEOSITE,geolocation-!cn," + groupName,
    "RULE-SET,loyalsoldier-direct,DIRECT",
    "RULE-SET,loyalsoldier-cncidr,DIRECT,no-resolve",
    "MATCH," + groupName
  ];

  config.rules = [inboundRule].concat(claudeRules, lanRules, subscriptionRules, domesticRules);

  // 使用 Mihomo 官方生态 MetaCubeX 数据，每日更新；失败时继续保留本地旧文件。
  config["geo-auto-update"] = true;
  config["geo-update-interval"] = 24;
  if (!config["geox-url"]) {
    config["geox-url"] = {};
  }
  config["geox-url"].geoip = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat";
  config["geox-url"].geosite = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat";
  config["geox-url"].mmdb = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb";
  config["geox-url"].asn = "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb";

  return config;
}
