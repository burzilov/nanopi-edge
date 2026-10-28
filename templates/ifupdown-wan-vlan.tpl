# nanopi-edge WAN: PPPoE поверх VLAN @VLAN@ (managed, do not edit)
auto @WAN@
iface @WAN@ inet manual
    pre-up ip link set dev @WAN@ up

auto @WAN@.@VLAN@
iface @WAN@.@VLAN@ inet manual
    pre-up ip link show dev @WAN@.@VLAN@ >/dev/null 2>&1 || ip link add link @WAN@ name @WAN@.@VLAN@ type vlan id @VLAN@
    pre-up ip link set dev @WAN@.@VLAN@ up
    post-down ip link delete dev @WAN@.@VLAN@ 2>/dev/null || true
