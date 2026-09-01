# NanoPi lab: WAN (@WAN@) в LAN домашнего роутера
network:
  version: 2
  renderer: networkd
  ethernets:
    @WAN@:
      dhcp4: true
      dhcp6: false
