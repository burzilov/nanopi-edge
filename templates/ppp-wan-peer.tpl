# NanoPi WAN PPPoE client → ISP
plugin rp-pppoe.so
@NIC@
user "@PPPOE_USER@"
noipdefault
defaultroute
replacedefaultroute
persist
maxfail 0
holdoff 5
mtu 1492
mru 1492
usepeerdns
lcp-echo-interval 30
lcp-echo-failure 4
nodetach
