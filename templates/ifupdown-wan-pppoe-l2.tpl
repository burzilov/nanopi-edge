# nanopi-edge WAN: L2 для PPPoE, без IP (managed, do not edit)
auto @WAN@
iface @WAN@ inet manual
    pre-up ip link set dev @WAN@ up
