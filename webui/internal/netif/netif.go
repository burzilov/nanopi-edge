// Package netif — автоопределение сетевых интерфейсов, когда в .env нет WAN_IF.
package netif

import (
	"os/exec"
	"strings"
)

// skipPrefixes — не физический WAN: PPPoE, TUN sing-box, WireGuard, loopback.
var skipPrefixes = []string{"ppp", "tun", "tap", "sb-", "wg", "lo"}

// ParseDefaultRoute — интерфейс из вывода `ip -4 route show default`
// (первый маршрут не через ppp*/tun*/…); "" если нет.
func ParseDefaultRoute(out string) string {
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		for i := 0; i+1 < len(f); i++ {
			if f[i] != "dev" {
				continue
			}
			dev := f[i+1]
			skip := false
			for _, p := range skipPrefixes {
				if strings.HasPrefix(dev, p) {
					skip = true
					break
				}
			}
			if !skip {
				return dev
			}
		}
	}
	return ""
}

// DefaultRouteIface — интерфейс маршрута по умолчанию (подменяется в тестах).
var DefaultRouteIface = func() string {
	out, err := exec.Command("ip", "-4", "route", "show", "default").Output()
	if err != nil {
		return ""
	}
	return ParseDefaultRoute(string(out))
}
