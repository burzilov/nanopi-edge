# NanoPi WAN PPPoE поверх VLAN @VLAN@
network:
  version: 2
  renderer: networkd
  ethernets:
    @WAN@:
      dhcp4: false
      dhcp6: false
      optional: true
  vlans:
    @WAN@.@VLAN@:
      id: @VLAN@
      link: @WAN@
      dhcp4: false
      dhcp6: false
