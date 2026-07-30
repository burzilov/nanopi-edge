package proxymgr

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"nanopi-webui/internal/hairpin"
	"nanopi-webui/internal/portfwd"
)

const (
	DefaultConfigPath = "/opt/nanopi-edge/proxy-manager.json"
	ruleComment       = "nginx-proxy-manager"
)

// Config — единственная ручная настройка: IP Nginx Proxy Manager в домашней LAN.
// Пустой ProxyIP = обвязка выключена.
type Config struct {
	ProxyIP  string `json:"proxy_ip,omitempty"`
	RouterIP string `json:"router_ip,omitempty"` // последний обнаруженный WAN роутера
}

func ConfigPath() string {
	if v := os.Getenv("PROXY_MANAGER_CONFIG"); v != "" {
		return v
	}
	return DefaultConfigPath
}

func Load() (Config, error) {
	b, err := os.ReadFile(ConfigPath())
	if err != nil {
		if os.IsNotExist(err) {
			return Config{}, nil
		}
		return Config{}, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return Config{}, err
	}
	c.ProxyIP = strings.TrimSpace(c.ProxyIP)
	c.RouterIP = strings.TrimSpace(c.RouterIP)
	return c, nil
}

func save(c Config) error {
	path := ConfigPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Status для страницы Nginx Proxy Manager.
type Status struct {
	Enabled   bool
	ProxyIP   string
	RouterIP  string
	RouterOK  bool
	ForwardIP string // куда DNAT с улицы (WAN роутера)
	HomeNet   string
	HairpinOn bool
	WhiteIPs  []string
	Hint      string
}

func GetStatus() (Status, error) {
	c, err := Load()
	if err != nil {
		return Status{}, err
	}
	st := Status{
		ProxyIP:  c.ProxyIP,
		Enabled:  c.ProxyIP != "",
		WhiteIPs: hairpin.WanIPv4s(),
	}
	if hs, err := hairpin.GetStatus(); err == nil {
		st.HairpinOn = hs.Active
	}
	detected := DetectRouterIP()
	if detected != "" {
		st.RouterIP = detected
		st.RouterOK = true
	} else if c.RouterIP != "" {
		st.RouterIP = c.RouterIP
		st.RouterOK = false
		st.Hint = "Роутер сейчас не отвечает в сети NanoPi; показан последний известный адрес. Проверьте кабель LAN NanoPi → WAN роутера."
	}
	if st.Enabled {
		st.ForwardIP = st.RouterIP
		if netCIDR, err := homeNetCIDR(c.ProxyIP); err == nil {
			st.HomeNet = netCIDR
		}
	}
	if st.Enabled && st.RouterIP == "" {
		st.Hint = "Не удалось найти домашний роутер в сети 10.10.10.0/24. Проверьте, что кабель идёт с LAN NanoPi на WAN роутера и роутер включён."
	}
	if st.Enabled {
		if st.Hint != "" {
			st.Hint += " "
		}
		st.Hint += "На роутере (например Keenetic) нужен проброс портов TCP 80 и 443 с WAN на Nginx Proxy Manager. У клиентов в домашней сети в качестве DNS укажите 10.10.10.1 — тогда домены из дома откроются на виртуалку."
	}
	return st, nil
}

// Apply включает обвязку (или Disable при пустом proxyIP).
// С улицы DNAT идёт на WAN роутера (его проброс → Nginx Proxy Manager);
// из дома — DNS alias на Nginx Proxy Manager.
func Apply(proxyIP string) error {
	proxyIP = strings.TrimSpace(proxyIP)
	if proxyIP == "" {
		return Disable()
	}
	ip := net.ParseIP(proxyIP)
	if ip == nil || ip.To4() == nil {
		return fmt.Errorf("нужен обычный IPv4-адрес Nginx Proxy Manager, например 192.168.1.137")
	}
	proxyIP = ip.String()

	router := DetectRouterIP()
	if router == "" {
		if c, err := Load(); err == nil && c.RouterIP != "" {
			router = c.RouterIP
		}
	}
	if router == "" {
		return fmt.Errorf("не найден домашний роутер в сети NanoPi — проверьте кабель LAN NanoPi → WAN роутера и что роутер включён")
	}
	if _, err := homeNetCIDR(proxyIP); err != nil {
		return err
	}

	// Dest = WAN роутера: на Keenetic уже есть (или нужен) проброс на Nginx Proxy Manager.
	// Прямой DNAT на 192.168.1.x ломает внешний доступ без отдельного МЭ под public src.
	s := portfwd.Store{
		Rules: []portfwd.Rule{
			portfwd.NormalizeRule(portfwd.Rule{
				Proto: "tcp", WanPort: 80, DestIP: router, DestPort: 80, Comment: ruleComment,
			}),
			portfwd.NormalizeRule(portfwd.Rule{
				Proto: "tcp", WanPort: 443, DestIP: router, DestPort: 443, Comment: ruleComment,
			}),
		},
	}
	s.Rules[0].Enabled = true
	s.Rules[1].Enabled = true
	if err := portfwd.Apply(s, true); err != nil {
		return err
	}
	if err := hairpin.Apply(proxyIP); err != nil {
		return fmt.Errorf("DNS hairpin: %w", err)
	}
	return save(Config{ProxyIP: proxyIP, RouterIP: router})
}

// Disable снимает DNAT, маршрут и DNS alias.
func Disable() error {
	if err := portfwd.Apply(portfwd.Store{Rules: []portfwd.Rule{}}, true); err != nil {
		return err
	}
	if err := hairpin.Apply(""); err != nil {
		return fmt.Errorf("DNS hairpin: %w", err)
	}
	_ = os.Remove(ConfigPath())
	return nil
}

func homeNetCIDR(proxyIP string) (string, error) {
	ip := net.ParseIP(proxyIP)
	if ip == nil {
		return "", fmt.Errorf("не IPv4")
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return "", fmt.Errorf("не IPv4")
	}
	return fmt.Sprintf("%d.%d.%d.0/24", ip4[0], ip4[1], ip4[2]), nil
}

// DetectRouterIP — сосед/арендатор в LAN NanoPi (обычно WAN Keenetic), не мы сами.
func DetectRouterIP() string {
	lanIF := portfwd.LanInterface()
	our := ourIPv4(lanIF)
	candidates := map[string]int{} // ip → score

	for _, ip := range dnsmasqLeaseIPs() {
		if skipNeighbor(ip, our) {
			continue
		}
		candidates[ip] += 2
	}
	for ip, state := range neighIPv4(lanIF) {
		if skipNeighbor(ip, our) {
			continue
		}
		candidates[ip] += 1
		switch state {
		case "REACHABLE", "DELAY", "PROBE":
			candidates[ip] += 3
		case "STALE":
			candidates[ip] += 1
		}
	}
	if c, err := Load(); err == nil && c.RouterIP != "" && !skipNeighbor(c.RouterIP, our) {
		candidates[c.RouterIP] += 1
	}

	best, bestScore := "", -1
	for ip, sc := range candidates {
		if sc > bestScore || (sc == bestScore && (best == "" || ip < best)) {
			best, bestScore = ip, sc
		}
	}
	return best
}

func skipNeighbor(ip string, our string) bool {
	if ip == "" || ip == our {
		return true
	}
	parsed := net.ParseIP(ip)
	if parsed == nil || parsed.To4() == nil || parsed.IsLoopback() {
		return true
	}
	// только типичный сегмент dual-serve NanoPi
	if our != "" {
		a := net.ParseIP(our).To4()
		b := parsed.To4()
		if a != nil && b != nil && (a[0] != b[0] || a[1] != b[1] || a[2] != b[2]) {
			return true
		}
	}
	return false
}

func ourIPv4(ifc string) string {
	cmd := exec.Command("ip", "-4", "-o", "addr", "show", "dev", ifc)
	b, err := cmd.Output()
	if err != nil {
		return "10.10.10.1"
	}
	for _, line := range strings.Split(string(b), "\n") {
		fields := strings.Fields(line)
		for i, f := range fields {
			if f == "inet" && i+1 < len(fields) {
				ip, _, err := net.ParseCIDR(fields[i+1])
				if err == nil && ip.To4() != nil {
					return ip.String()
				}
			}
		}
	}
	return "10.10.10.1"
}

func neighIPv4(ifc string) map[string]string {
	out := map[string]string{}
	cmd := exec.Command("ip", "-4", "neigh", "show", "dev", ifc)
	b, err := cmd.Output()
	if err != nil {
		return out
	}
	sc := bufio.NewScanner(strings.NewReader(string(b)))
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 4 {
			continue
		}
		ip := fields[0]
		state := fields[len(fields)-1]
		out[ip] = state
	}
	return out
}

func dnsmasqLeaseIPs() []string {
	paths := []string{
		"/var/lib/misc/dnsmasq.leases",
		"/var/lib/dnsmasq/dnsmasq.leases",
	}
	var ips []string
	seen := map[string]struct{}{}
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			fields := strings.Fields(sc.Text())
			// expiry mac ip hostname clientid
			if len(fields) < 3 {
				continue
			}
			ip := fields[2]
			if net.ParseIP(ip) == nil {
				continue
			}
			if _, ok := seen[ip]; ok {
				continue
			}
			seen[ip] = struct{}{}
			ips = append(ips, ip)
		}
		f.Close()
	}
	return ips
}
