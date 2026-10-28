{
  "$schema": "https://sing-box.sagernet.org/schema.json",
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "http_clients": [
    {
      "tag": "ruleset-direct"
    }
  ],
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "dns-proxy",
        "server": "94.140.14.14",
        "server_port": 443,
        "path": "/dns-query",
        "tls": {
          "enabled": true,
          "server_name": "dns.adguard-dns.com"
        },
        "detour": "proxy"
      },
      {
        "type": "https",
        "tag": "dns-direct",
        "server": "94.140.14.14",
        "server_port": 443,
        "path": "/dns-query",
        "tls": {
          "enabled": true,
          "server_name": "dns.adguard-dns.com"
        }
      }
    ],
    "rules": [
      {
        "domain_suffix": [],
        "action": "route",
        "server": "dns-proxy"
      },
      {
        "rule_set": [
          "geosite-category-ai-!cn",
          "geosite-ru-blocked",
          "geosite-telegram"
        ],
        "action": "route",
        "server": "dns-proxy"
      },
      {
        "domain_suffix": [".ru", ".su", ".рф", ".xn--p1ai"],
        "action": "route",
        "server": "dns-direct"
      },
      {
        "action": "evaluate",
        "server": "dns-proxy",
        "timeout": "3s"
      },
      {
        "match_response": true,
        "response_rcode": "NOERROR",
        "action": "respond"
      },
      {
        "match_response": true,
        "response_rcode": "NXDOMAIN",
        "action": "respond"
      },
      {
        "action": "route",
        "server": "dns-direct"
      }
    ],
    "final": "dns-direct",
    "strategy": "ipv4_only",
    "timeout": "10s"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sb-tun",
      "address": ["172.19.0.1/30"],
      "mtu": 1500,
      "auto_route": true,
      "strict_route": false,
      "stack": "mixed",
      "route_exclude_address": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
      "auto_redirect": true,
      "exclude_interface": ["@WAN_IF@"]
    }
  ],
  "outbounds": [],
  "route": {
    "rules": [
      {
        "action": "reject",
        "ip_cidr": ["169.254.0.0/16"]
      },
      {
        "port": 53,
        "action": "hijack-dns"
      },
      {
        "action": "route",
        "outbound": "direct",
        "ip_is_private": true
      },
      {
        "action": "sniff",
        "timeout": "300ms"
      },
      {
        "port": 853,
        "action": "reject"
      },
      {
        "action": "route",
        "outbound": "proxy",
        "ip_cidr": [
          "94.140.14.14/32",
          "94.140.15.15/32",
          "9.9.9.9/32"
        ]
      },
      {
        "action": "route",
        "outbound": "direct",
        "protocol": "bittorrent"
      },
      {
        "action": "route",
        "outbound": "proxy",
        "domain_suffix": [
          "2ip.io",
          "ipify.org",
          "googlevideo.com",
          "cursor.com",
          "cursor.sh",
          "cursor-cdn.com",
          "cursorapi.com",
          "cursorvm.com",
          "vercel.app",
          "opencode.ai",
          "parallel.ai",
          "scdn.co",
          "spotifycdn.com",
          "bip.com"
        ]
      },
      {
        "action": "route",
        "outbound": "proxy",
        "rule_set": [
          "geosite-category-ai-!cn",
          "geosite-ru-blocked",
          "geoip-ru-blocked",
          "geosite-telegram",
          "geoip-telegram"
        ]
      },
      {
        "action": "route",
        "outbound": "direct",
        "domain_suffix": [".ru", ".su", ".рф", ".xn--p1ai"]
      }
    ],
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-ru-blocked",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-ru-blocked.srs",
        "update_interval": "6h"
      },
      {
        "type": "remote",
        "tag": "geoip-ru-blocked",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-ru-blocked.srs",
        "update_interval": "6h"
      },
      {
        "type": "remote",
        "tag": "geosite-category-ai-!cn",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-category-ai-!cn.srs",
        "update_interval": "6h"
      },
      {
        "type": "remote",
        "tag": "geosite-telegram",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geosite/geosite-telegram.srs",
        "update_interval": "6h"
      },
      {
        "type": "remote",
        "tag": "geoip-telegram",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/sing-box/rule-set-geoip/geoip-telegram.srs",
        "update_interval": "6h"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true,
    "default_http_client": "ruleset-direct",
    "default_domain_resolver": "dns-direct"
  },
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "/var/lib/sing-box/cache.db",
      "store_dns": true
    },
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": "@CLASH_SECRET@"
    }
  }
}
