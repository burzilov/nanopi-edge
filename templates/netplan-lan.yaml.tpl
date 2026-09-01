# NanoPi router: LAN (@LAN@) = 10.10.10.1/24
network:
  version: 2
  renderer: networkd
  ethernets:
    @LAN@:
      dhcp4: false
      dhcp6: false
      optional: true
      ignore-carrier: true
      addresses:
        - 10.10.10.1/24
