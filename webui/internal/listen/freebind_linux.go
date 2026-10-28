//go:build linux

package listen

import "syscall"

func freebindControl(network, address string, c syscall.RawConn) error {
	var serr error
	err := c.Control(func(fd uintptr) {
		lvl, opt := syscall.SOL_IP, syscall.IP_FREEBIND
		if network == "tcp6" {
			// IPV6_FREEBIND = 78 (linux/in6.h); для v6-сокета IP_FREEBIND тоже
			// работает с ядра 4.15, но явная опция надёжнее.
			lvl, opt = syscall.SOL_IPV6, 78
		}
		serr = syscall.SetsockoptInt(int(fd), lvl, opt, 1)
	})
	if err != nil {
		return err
	}
	return serr
}
