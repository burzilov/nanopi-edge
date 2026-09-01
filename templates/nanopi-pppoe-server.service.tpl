[Unit]
Description=NanoPi LAN PPPoE server (accept-any)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/pppoe-server -F -I @LAN@ -L 10.10.10.1 -R 10.10.10.2 -N 1 -C nanopi
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
