// Package listen — TCP-слушатель панели.
//
// На свежей установке адреса LAN (10.10.10.1) ещё нет: его назначает router-on.
// Обычный bind на такой адрес падает с EADDRNOTAVAIL, и systemd перезапускает
// панель по кругу. На Linux слушатель ставит IP_FREEBIND: сокет привязывается к
// адресу заранее и начинает принимать соединения, как только адрес появится на
// интерфейсе. Там, где адрес уже есть (NanoPi после router-on), поведение то же.
package listen

import (
	"context"
	"net"
	"net/netip"
)

// Listen открывает TCP-слушатель на addr (host:port) с IP_FREEBIND, где он есть.
func Listen(ctx context.Context, addr string) (net.Listener, error) {
	lc := net.ListenConfig{Control: freebindControl}
	return lc.Listen(ctx, "tcp", addr)
}

// AddrPresent сообщает, назначен ли IP из addr (host:port) локальному интерфейсу.
// Пустой хост и 0.0.0.0/:: считаются присутствующими. При ошибке разбора — true
// (не мешаем старту, ошибку покажет сам Listen).
func AddrPresent(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return true
	}
	if host == "" {
		return true
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return true
	}
	if ip.IsUnspecified() || ip.IsLoopback() {
		return true
	}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return true
	}
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok {
			if p, ok := netip.AddrFromSlice(n.IP); ok && p.Unmap() == ip.Unmap() {
				return true
			}
		}
	}
	return false
}
