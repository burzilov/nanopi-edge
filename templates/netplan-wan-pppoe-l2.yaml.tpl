# NanoPi WAN: L2 для PPPoE (без DHCP)
network:
  version: 2
  renderer: networkd
  ethernets:
    @WAN@:
      dhcp4: false
      dhcp6: false
      optional: true
