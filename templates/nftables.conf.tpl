#!/usr/sbin/nft -f
# Минимальный NAT на краю + MSS clamp для PPPoE
flush ruleset

table inet nat {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "@WAN@" masquerade
		oifname "ppp0" masquerade
	}
}

table inet filter {
	chain forward {
		type filter hook forward priority filter; policy accept;
		tcp flags syn tcp option maxseg size set 1452
	}
}

include "/etc/nftables.d/nanopi-port-forwards.nft"
