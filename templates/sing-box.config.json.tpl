{
  "$schema": "https://sing-box.sagernet.org/schema.json",
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "http_clients": [
    {
      "tag": "ruleset-direct",
      "detour": "direct"
    }
  ],
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local"
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
      },
      {
        "type": "https",
        "tag": "dns-quad9",
        "server": "9.9.9.9",
        "server_port": 443,
        "path": "/dns-query",
        "tls": {
          "enabled": true,
          "server_name": "dns.quad9.net"
        }
      }
    ],
    "rules": [
      {
        "action": "evaluate",
        "server": "dns-direct",
        "tag": "dns-direct"
      },
      {
        "action": "evaluate",
        "server": "dns-quad9",
        "tag": "dns-quad9"
      },
      {
        "match_response": "dns-direct",
        "response_rcode": "NOERROR",
        "ip_accept_any": true,
        "action": "respond",
        "race": true
      },
      {
        "match_response": "dns-quad9",
        "response_rcode": "NOERROR",
        "ip_accept_any": true,
        "action": "respond",
        "race": true
      },
      {
        "action": "route",
        "server": "dns-quad9"
      }
    ],
    "final": "dns-quad9",
    "strategy": "ipv4_only",
    "timeout": "10s"
  },
  "inbounds": [
    {
      "type": "direct",
      "tag": "dns-in",
      "listen": "127.0.0.1",
      "listen_port": 5353,
      "network": "udp"
    },
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
        "inbound": ["dns-in"],
        "action": "hijack-dns"
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
        "outbound": "direct",
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
        "domain_suffix": ["2ip.io", "ipify.org"]
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
        "domain_suffix": [".ru", ".su", ".рф"]
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
