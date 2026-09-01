# NanoPi router: WAN (@WAN@) = DHCP от ISP
network:
  version: 2
  renderer: networkd
  ethernets:
    @WAN@:
      dhcp4: true
      dhcp6: false
      dhcp4-overrides:
        route-metric: 100
