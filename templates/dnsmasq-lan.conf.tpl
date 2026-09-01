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
# Клиентский DNS → sing-box (inbound dns-in :5353); upstream DoH — в config.json
server=127.0.0.1#5353
