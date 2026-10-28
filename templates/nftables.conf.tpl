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
	# SSH роутера — только с LAN: новые соединения на порт(ы) sshd с WAN/ppp0 — drop
	# (порт из `sshd -T`; SSH_ALLOW_WAN=1 в /opt/nanopi-edge/.env — не закрывать).
	chain input {
		type filter hook input priority filter; policy accept;
		@SSH_WAN_RULE@
	}

	chain forward {
		type filter hook forward priority filter; policy accept;
		tcp flags syn tcp option maxseg size set 1452
	}
}

include "/etc/nftables.d/nanopi-port-forwards.nft"
