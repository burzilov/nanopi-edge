# DHCP только на LAN NanoPi → WAN домашнего роутера
interface=@LAN@
bind-dynamic
except-interface=lo
except-interface=@WAN@
except-interface=sb-tun
except-interface=ppp0
except-interface=ppp1

domain-needed
bogus-priv
dhcp-authoritative

dhcp-range=10.10.10.100,10.10.10.200,12h
dhcp-option=option:router,10.10.10.1
dhcp-option=option:dns-server,10.10.10.1

no-resolv
# Upstream — AdGuard DNS (UDP/53). Пока sing-box жив, эти запросы перехватывает TUN
# (route-правило port 53 → hijack-dns) и резолвит sing-box: AdGuard DoH через proxy,
# фолбэк — тот же AdGuard напрямую; .ru/.su/.рф — напрямую (см. dns в config.json).
# dnsmasq связан с sing-box через Requires= (drop-in): systemctl stop sing-box гасит и dnsmasq.
server=94.140.14.14
server=94.140.15.15
