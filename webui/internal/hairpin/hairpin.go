package hairpin

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"nanopi-webui/internal/config"
	"nanopi-webui/internal/netif"
)

const (
	EnvKey      = "HAIRPIN_DNS_TARGET"
	DefaultConf = "/etc/dnsmasq.d/hairpin-alias.conf"
)

func EnvPath() string {
	return config.DefaultEnvPath()
}

func ConfPath() string {
	if v := os.Getenv("HAIRPIN_DNS_CONF"); v != "" {
		return v
	}
	return DefaultConf
}

func RefreshScript() string {
	if v := os.Getenv("HAIRPIN_DNS_SCRIPT"); v != "" {
		return v
	}
	return "/opt/nanopi-edge/scripts/hairpin-dns-refresh"
}

// Status для страницы портов.
type Status struct {
	Target    string          `json:"target"`
	WanIPs    []string        `json:"wan_ips"`
	Active    bool            `json:"active"`
	Overrides []OverrideState `json:"overrides"`
}

// OverrideState — исключение и признак, что оно уже записано в конфиг dnsmasq.
type OverrideState struct {
	Override
	Applied bool `json:"applied"`
}

func GetTarget() (string, error) {
	v, _, err := config.GetKV(EnvPath(), EnvKey)
	return strings.TrimSpace(v), err
}

func WanIPv4s() []string {
	wanIF := ""
	if v, ok, _ := config.GetKV(EnvPath(), "WAN_IF"); ok && v != "" {
		wanIF = v
	} else {
		wanIF = netif.DefaultRouteIface()
	}
	seen := map[string]struct{}{}
	var out []string
	for _, ifc := range []string{wanIF, "ppp0"} {
		if ifc == "" {
			continue
		}
		for _, ip := range addrsOn(ifc) {
			if _, ok := seen[ip]; ok {
				continue
			}
			seen[ip] = struct{}{}
			out = append(out, ip)
		}
	}
	return out
}

func addrsOn(ifc string) []string {
	cmd := exec.Command("ip", "-4", "-o", "addr", "show", "dev", ifc)
	b, err := cmd.Output()
	if err != nil {
		return nil
	}
	var ips []string
	for _, line := range strings.Split(string(b), "\n") {
		fields := strings.Fields(line)
		for i, f := range fields {
			if f == "inet" && i+1 < len(fields) {
				ip, _, err := net.ParseCIDR(fields[i+1])
				if err != nil {
					ip = net.ParseIP(fields[i+1])
				}
				if ip != nil && ip.To4() != nil {
					ips = append(ips, ip.String())
				}
			}
		}
	}
	return ips
}

func GetStatus() (Status, error) {
	t, err := GetTarget()
	if err != nil {
		return Status{}, err
	}
	ov, err := LoadOverrides()
	if err != nil {
		return Status{}, err
	}
	wan := WanIPv4s()
	conf, _ := os.ReadFile(ConfPath())
	active := t != "" && len(wan) > 0
	if active && conf != nil {
		active = strings.Contains(string(conf), "alias=") && strings.Contains(string(conf), t)
	}
	st := Status{Target: t, WanIPs: wan, Active: active, Overrides: make([]OverrideState, 0, len(ov))}
	for _, o := range ov {
		line := "address=/" + o.Name + "/" + o.IP + "\n"
		st.Overrides = append(st.Overrides, OverrideState{Override: o, Applied: strings.Contains(string(conf), line)})
	}
	return st, nil
}

// NormalizeTarget проверяет адрес подмены и приводит его к виду a.b.c.d.
// Пусто — подмена выключена.
func NormalizeTarget(s string) (string, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", nil
	}
	ip := net.ParseIP(s)
	if ip == nil || ip.To4() == nil || strings.Contains(s, ":") {
		return "", fmt.Errorf("нужен IPv4-адрес в домашней сети, например 192.168.1.137, или пустое поле — подмена выключена")
	}
	ip = ip.To4()
	if ip.IsUnspecified() || ip.IsLoopback() || ip.IsMulticast() || ip.Equal(net.IPv4bcast) {
		return "", fmt.Errorf("адрес %s не подходит: нужен обычный адрес устройства в домашней сети", ip)
	}
	return ip.String(), nil
}

func ValidateTarget(s string) error {
	_, err := NormalizeTarget(s)
	return err
}

// Apply сохраняет target в .env и применяет конфиг (Refresh).
func Apply(target string) error {
	target, err := NormalizeTarget(target)
	if err != nil {
		return err
	}
	if target == "" {
		if err := config.DeleteKV(EnvPath(), EnvKey); err != nil {
			return err
		}
	} else {
		if err := config.SetKV(EnvPath(), EnvKey, target); err != nil {
			return err
		}
	}
	return Refresh()
}

// Refresh перегенерирует hairpin-alias.conf (общая подмена + исключения) и
// перезапускает dnsmasq. Предпочитаем скрипт edge (тот же код, что CLI).
func Refresh() error {
	if scr := RefreshScript(); fileExecutable(scr) {
		cmd := exec.Command(scr)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("hairpin-dns-refresh: %w (%s)", err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	target, err := GetTarget()
	if err != nil {
		return err
	}
	if target, err = NormalizeTarget(target); err != nil {
		return err
	}
	ov, err := LoadOverrides()
	if err != nil {
		return err
	}
	return applyLocal(target, ov)
}

func fileExecutable(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !st.IsDir() && st.Mode()&0o111 != 0
}

func applyLocal(target string, ov []Override) error {
	conf := ConfPath()
	if err := os.MkdirAll(filepath.Dir(conf), 0o755); err != nil {
		return err
	}
	if content := RenderConf(target, WanIPv4s(), ov); content == "" {
		_ = os.Remove(conf)
	} else {
		tmp := conf + ".tmp"
		if err := os.WriteFile(tmp, []byte(content), 0o644); err != nil {
			return err
		}
		if err := os.Rename(tmp, conf); err != nil {
			return err
		}
	}
	cmd := exec.Command("systemctl", "restart", "dnsmasq")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl restart dnsmasq: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}
