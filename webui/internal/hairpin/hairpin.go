package hairpin

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"nanopi-webui/internal/config"
)

const (
	EnvKey     = "HAIRPIN_DNS_TARGET"
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
	Target string   `json:"target"`
	WanIPs []string `json:"wan_ips"`
	Active bool     `json:"active"`
}

func GetTarget() (string, error) {
	v, _, err := config.GetKV(EnvPath(), EnvKey)
	return strings.TrimSpace(v), err
}

func WanIPv4s() []string {
	wanIF := "end0"
	if v, ok, _ := config.GetKV(EnvPath(), "WAN_IF"); ok && v != "" {
		wanIF = v
	}
	seen := map[string]struct{}{}
	var out []string
	for _, ifc := range []string{wanIF, "ppp0"} {
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
	wan := WanIPv4s()
	active := t != "" && len(wan) > 0
	if active {
		if b, err := os.ReadFile(ConfPath()); err == nil {
			active = strings.Contains(string(b), "alias=") && strings.Contains(string(b), t)
		}
	}
	return Status{Target: t, WanIPs: wan, Active: active}, nil
}

func ValidateTarget(s string) error {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	ip := net.ParseIP(s)
	if ip == nil || ip.To4() == nil {
		return fmt.Errorf("нужен IPv4 или пусто")
	}
	return nil
}

// Apply сохраняет target в .env, пишет dnsmasq alias, рестартит dnsmasq.
func Apply(target string) error {
	target = strings.TrimSpace(target)
	if err := ValidateTarget(target); err != nil {
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
	// Предпочитаем скрипт edge (тот же код, что CLI).
	if scr := RefreshScript(); fileExecutable(scr) {
		cmd := exec.Command(scr)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("hairpin-dns-refresh: %w (%s)", err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	return applyLocal(target)
}

func fileExecutable(path string) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !st.IsDir() && st.Mode()&0o111 != 0
}

func applyLocal(target string) error {
	conf := ConfPath()
	if err := os.MkdirAll(filepath.Dir(conf), 0o755); err != nil {
		return err
	}
	if target == "" {
		_ = os.Remove(conf)
	} else {
		wan := WanIPv4s()
		var b strings.Builder
		b.WriteString("# Managed by nanopi-webui — hairpin DNS\n")
		b.WriteString("# HAIRPIN_DNS_TARGET=" + target + "\n")
		if len(wan) == 0 {
			b.WriteString("# WAN IPv4 пока нет\n")
		}
		for _, ip := range wan {
			if ip == target {
				continue
			}
			b.WriteString("alias=" + ip + "," + target + "\n")
		}
		tmp := conf + ".tmp"
		if err := os.WriteFile(tmp, []byte(b.String()), 0o644); err != nil {
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
