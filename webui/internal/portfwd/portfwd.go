package portfwd

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	DefaultStorePath = "/opt/nanopi-edge/port-forwards.json"
	DefaultNftPath   = "/etc/nftables.d/nanopi-port-forwards.nft"
	DefaultNftConf   = "/etc/nftables.conf"
	DefaultEnvPath   = "/opt/nanopi-edge/.env"
	MaxRules         = 64
)

type Rule struct {
	ID       string `json:"id"`
	Enabled  bool   `json:"enabled"`
	Proto    string `json:"proto"` // tcp | udp | both
	WanPort  int    `json:"wan_port"`
	DestIP   string `json:"dest_ip"`
	DestPort int    `json:"dest_port"`
	Comment  string `json:"comment,omitempty"`
}

// Store — правила DNAT + опция «заход с дома на белый IP» (VPN/обычный DNS).
type Store struct {
	// LanHairpin: DNAT с LAN NanoPi, когда dest = белый IP (иначе только с WAN/ppp0).
	LanHairpin bool   `json:"lan_hairpin"`
	HomeNet    string `json:"home_net,omitempty"` // напр. 192.168.1.0/24 (сеть за роутером)
	HomeVia    string `json:"home_via,omitempty"` // напр. 10.10.10.179 (WAN роутера на NanoPi LAN)
	Rules      []Rule `json:"rules"`
}

func StorePath() string {
	if v := os.Getenv("PORTFWD_STORE"); v != "" {
		return v
	}
	return DefaultStorePath
}

func NftPath() string {
	if v := os.Getenv("PORTFWD_NFT"); v != "" {
		return v
	}
	return DefaultNftPath
}

func NftConfPath() string {
	if v := os.Getenv("PORTFWD_NFT_CONF"); v != "" {
		return v
	}
	return DefaultNftConf
}

func EnvPath() string {
	if v := os.Getenv("WEBUI_ENV"); v != "" {
		return v
	}
	return DefaultEnvPath
}

func Load() (Store, error) {
	path := StorePath()
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Store{Rules: []Rule{}}, nil
		}
		return Store{}, err
	}
	var s Store
	if err := json.Unmarshal(b, &s); err != nil {
		return Store{}, fmt.Errorf("port-forwards.json: %w", err)
	}
	if s.Rules == nil {
		s.Rules = []Rule{}
	}
	return s, nil
}

func Save(s Store) error {
	if err := ValidateStore(s); err != nil {
		return err
	}
	path := StorePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(path), ".portfwd-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, path)
}

func ValidateStore(s Store) error {
	if s.LanHairpin {
		if _, n, err := net.ParseCIDR(strings.TrimSpace(s.HomeNet)); err != nil || n == nil {
			return fmt.Errorf("home_net: нужен CIDR, напр. 192.168.1.0/24")
		}
		ip := net.ParseIP(strings.TrimSpace(s.HomeVia))
		if ip == nil || ip.To4() == nil {
			return fmt.Errorf("home_via: нужен IPv4 WAN роутера (10.10.10.x)")
		}
	}
	if len(s.Rules) > MaxRules {
		return fmt.Errorf("слишком много правил (макс. %d)", MaxRules)
	}
	seen := map[string]struct{}{}
	for i, r := range s.Rules {
		if err := ValidateRule(r); err != nil {
			return fmt.Errorf("правило %d: %w", i+1, err)
		}
		key := fmt.Sprintf("%s/%d", strings.ToLower(r.Proto), r.WanPort)
		if r.Proto == "both" {
			key = fmt.Sprintf("both/%d", r.WanPort)
		}
		if _, ok := seen[key]; ok {
			return fmt.Errorf("дубликат WAN-порта %d (%s)", r.WanPort, r.Proto)
		}
		// both конфликтует с tcp/udp на том же порту
		if r.Proto == "both" {
			if _, ok := seen[fmt.Sprintf("tcp/%d", r.WanPort)]; ok {
				return fmt.Errorf("порт %d уже занят tcp", r.WanPort)
			}
			if _, ok := seen[fmt.Sprintf("udp/%d", r.WanPort)]; ok {
				return fmt.Errorf("порт %d уже занят udp", r.WanPort)
			}
		} else {
			if _, ok := seen[fmt.Sprintf("both/%d", r.WanPort)]; ok {
				return fmt.Errorf("порт %d уже занят both", r.WanPort)
			}
		}
		seen[key] = struct{}{}
	}
	return nil
}

func ValidateRule(r Rule) error {
	if r.ID == "" {
		return fmt.Errorf("пустой id")
	}
	proto := strings.ToLower(strings.TrimSpace(r.Proto))
	switch proto {
	case "tcp", "udp", "both":
	default:
		return fmt.Errorf("proto: tcp|udp|both")
	}
	if r.WanPort < 1 || r.WanPort > 65535 {
		return fmt.Errorf("wan_port вне 1–65535")
	}
	if r.DestPort < 1 || r.DestPort > 65535 {
		return fmt.Errorf("dest_port вне 1–65535")
	}
	ip := net.ParseIP(strings.TrimSpace(r.DestIP))
	if ip == nil || ip.To4() == nil {
		return fmt.Errorf("dest_ip: нужен IPv4")
	}
	if len(r.Comment) > 120 {
		return fmt.Errorf("comment слишком длинный")
	}
	return nil
}

func NewID() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func NormalizeRule(r Rule) Rule {
	r.Proto = strings.ToLower(strings.TrimSpace(r.Proto))
	r.DestIP = strings.TrimSpace(r.DestIP)
	r.Comment = strings.TrimSpace(r.Comment)
	if r.ID == "" {
		r.ID = NewID()
	}
	return r
}

// WanInterfaces — интерфейсы, с которых принимать DNAT (WAN ethernet, ppp0, VLAN).
func WanInterfaces() []string {
	wan := "end0"
	vlan := ""
	f, err := os.Open(EnvPath())
	if err == nil {
		defer f.Close()
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			k, v, ok := strings.Cut(line, "=")
			if !ok {
				continue
			}
			v = strings.Trim(v, `"'`)
			switch strings.TrimSpace(k) {
			case "WAN_IF":
				if v != "" {
					wan = v
				}
			case "PPPOE_VLAN":
				vlan = v
			}
		}
	}
	out := []string{wan, "ppp0"}
	if vlan != "" {
		if n, err := strconv.Atoi(vlan); err == nil && n >= 1 && n <= 4094 {
			out = append(out, fmt.Sprintf("%s.%d", wan, n))
		}
	}
	return out
}

// LanInterface — LAN NanoPi (к роутеру).
func LanInterface() string {
	lan := "enp1s0"
	f, err := os.Open(EnvPath())
	if err != nil {
		return lan
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		if strings.TrimSpace(k) == "LAN_IF" {
			v = strings.Trim(v, `"'`)
			if v != "" {
				return v
			}
		}
	}
	return lan
}

// WanIPv4s — текущие IPv4 на WAN/ppp0 (белый IP).
func WanIPv4s() []string {
	wan := "end0"
	f, err := os.Open(EnvPath())
	if err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			k, v, ok := strings.Cut(line, "=")
			if !ok {
				continue
			}
			if strings.TrimSpace(k) == "WAN_IF" {
				v = strings.Trim(v, `"'`)
				if v != "" {
					wan = v
				}
			}
		}
		f.Close()
	}
	seen := map[string]struct{}{}
	var out []string
	for _, ifc := range []string{wan, "ppp0"} {
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

// RenderNft строит содержимое /etc/nftables.d/nanopi-port-forwards.nft.
func RenderNft(s Store, wanIfaces []string, lanIF string, wanIPs []string) string {
	var b strings.Builder
	b.WriteString("# Managed by nanopi-webui — port forwards (do not edit)\n")
	b.WriteString("table inet nanopi_portforward {\n")
	b.WriteString("\tchain prerouting {\n")
	b.WriteString("\t\ttype nat hook prerouting priority dstnat; policy accept;\n")
	if len(wanIfaces) == 0 {
		wanIfaces = []string{"end0", "ppp0"}
	}
	ifaceList := quoteIfaceSet(wanIfaces)
	wanIPList := quoteIPSet(wanIPs)
	for _, r := range s.Rules {
		if !r.Enabled {
			continue
		}
		comment := ""
		if r.Comment != "" {
			comment = " # " + sanitizeComment(r.Comment)
		}
		protos := []string{r.Proto}
		if r.Proto == "both" {
			protos = []string{"tcp", "udp"}
		}
		for _, p := range protos {
			fmt.Fprintf(&b,
				"\t\tiifname { %s } %s dport %d dnat ip to %s:%d%s\n",
				ifaceList, p, r.WanPort, r.DestIP, r.DestPort, comment,
			)
			// Из дома (и при VPN): DNS → белый IP, пакет приходит на LAN NanoPi.
			if s.LanHairpin && lanIF != "" && wanIPList != "" {
				fmt.Fprintf(&b,
					"\t\tiifname %s ip daddr { %s } %s dport %d dnat ip to %s:%d%s\n",
					strconv.Quote(lanIF), wanIPList, p, r.WanPort, r.DestIP, r.DestPort, comment,
				)
			}
		}
	}
	b.WriteString("\t}\n")
	if s.LanHairpin && lanIF != "" && strings.TrimSpace(s.HomeNet) != "" {
		b.WriteString("\tchain postrouting {\n")
		b.WriteString("\t\ttype nat hook postrouting priority srcnat; policy accept;\n")
		fmt.Fprintf(&b,
			"\t\toifname %s ip daddr %s masquerade\n",
			strconv.Quote(lanIF), strings.TrimSpace(s.HomeNet),
		)
		b.WriteString("\t}\n")
	}
	b.WriteString("}\n")
	return b.String()
}

func quoteIPSet(ips []string) string {
	parts := make([]string, 0, len(ips))
	seen := map[string]struct{}{}
	for _, ip := range ips {
		ip = strings.TrimSpace(ip)
		if ip == "" {
			continue
		}
		if _, ok := seen[ip]; ok {
			continue
		}
		seen[ip] = struct{}{}
		parts = append(parts, ip)
	}
	return strings.Join(parts, ", ")
}

func quoteIfaceSet(ifaces []string) string {
	parts := make([]string, 0, len(ifaces))
	seen := map[string]struct{}{}
	for _, ifn := range ifaces {
		ifn = strings.TrimSpace(ifn)
		if ifn == "" {
			continue
		}
		if _, ok := seen[ifn]; ok {
			continue
		}
		seen[ifn] = struct{}{}
		parts = append(parts, strconv.Quote(ifn))
	}
	return strings.Join(parts, ", ")
}

func sanitizeComment(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", "")
	return s
}

func EnsureNftInclude(confPath string) error {
	b, err := os.ReadFile(confPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("нет %s — сначала router-on", confPath)
		}
		return err
	}
	needle := "nanopi-port-forwards.nft"
	if strings.Contains(string(b), needle) {
		return nil
	}
	f, err := os.OpenFile(confPath, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.WriteString("\ninclude \"/etc/nftables.d/nanopi-port-forwards.nft\"\n"); err != nil {
		return err
	}
	return nil
}

func WriteNftFile(s Store) error {
	path := NftPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	content := RenderNft(s, WanInterfaces(), LanInterface(), WanIPv4s())
	tmp, err := os.CreateTemp(filepath.Dir(path), ".nft-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, path)
}

func ReloadNftables() error {
	conf := NftConfPath()
	cmd := exec.Command("nft", "-f", conf)
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			return fmt.Errorf("nft -f %s: %w", conf, err)
		}
		return fmt.Errorf("nft -f %s: %w\n%s", conf, err, msg)
	}
	// /etc/nftables.conf начинается с flush ruleset — сносит auto_redirect sing-box.
	_ = exec.Command("systemctl", "try-reload-or-restart", "sing-box").Run()
	return nil
}

// EnsureHomeRoute ставит маршрут в домашнюю LAN за роутером (нужен при dest=192.168.x.x).
func EnsureHomeRoute(s Store) error {
	unit := "/etc/systemd/system/nanopi-home-route.service"
	if !s.LanHairpin {
		_ = exec.Command("systemctl", "disable", "--now", "nanopi-home-route.service").Run()
		_ = os.Remove(unit)
		_ = exec.Command("systemctl", "daemon-reload").Run()
		return nil
	}
	lan := LanInterface()
	netCIDR := strings.TrimSpace(s.HomeNet)
	via := strings.TrimSpace(s.HomeVia)
	cmd := exec.Command("ip", "route", "replace", netCIDR, "via", via, "dev", lan)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ip route replace: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	body := fmt.Sprintf(`[Unit]
Description=NanoPi route to home LAN behind CPE
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip route replace %s via %s dev %s

[Install]
WantedBy=multi-user.target
`, netCIDR, via, lan)
	if err := os.WriteFile(unit, []byte(body), 0o644); err != nil {
		return err
	}
	_ = exec.Command("systemctl", "daemon-reload").Run()
	if out, err := exec.Command("systemctl", "enable", "--now", "nanopi-home-route.service").CombinedOutput(); err != nil {
		return fmt.Errorf("enable nanopi-home-route: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Apply сохраняет store (если save), пишет nft-файл, маршрут, перезагружает ruleset.
func Apply(s Store, save bool) error {
	if err := ValidateStore(s); err != nil {
		return err
	}
	if save {
		if err := Save(s); err != nil {
			return err
		}
	}
	if err := EnsureHomeRoute(s); err != nil {
		return err
	}
	if err := WriteNftFile(s); err != nil {
		return err
	}
	if err := EnsureNftInclude(NftConfPath()); err != nil {
		return err
	}
	return ReloadNftables()
}

// SetLanHairpin обновляет опцию lan hairpin и применяет.
func SetLanHairpin(enabled bool, homeNet, homeVia string) (Store, error) {
	s, err := Load()
	if err != nil {
		return s, err
	}
	s.LanHairpin = enabled
	s.HomeNet = strings.TrimSpace(homeNet)
	s.HomeVia = strings.TrimSpace(homeVia)
	if !enabled {
		s.HomeNet = ""
		s.HomeVia = ""
	}
	if err := Apply(s, true); err != nil {
		return s, err
	}
	return s, nil
}

func Add(r Rule) (Store, error) {
	s, err := Load()
	if err != nil {
		return s, err
	}
	r = NormalizeRule(r)
	r.Enabled = true
	if err := ValidateRule(r); err != nil {
		return s, err
	}
	s.Rules = append(s.Rules, r)
	if err := Apply(s, true); err != nil {
		return s, err
	}
	return s, nil
}

func Delete(id string) (Store, error) {
	s, err := Load()
	if err != nil {
		return s, err
	}
	id = strings.TrimSpace(id)
	out := s.Rules[:0]
	found := false
	for _, r := range s.Rules {
		if r.ID == id {
			found = true
			continue
		}
		out = append(out, r)
	}
	if !found {
		return s, fmt.Errorf("правило %s не найдено", id)
	}
	s.Rules = out
	if err := Apply(s, true); err != nil {
		return s, err
	}
	return s, nil
}

func SetEnabled(id string, enabled bool) (Store, error) {
	s, err := Load()
	if err != nil {
		return s, err
	}
	found := false
	for i := range s.Rules {
		if s.Rules[i].ID == id {
			s.Rules[i].Enabled = enabled
			found = true
			break
		}
	}
	if !found {
		return s, fmt.Errorf("правило %s не найдено", id)
	}
	if err := Apply(s, true); err != nil {
		return s, err
	}
	return s, nil
}
