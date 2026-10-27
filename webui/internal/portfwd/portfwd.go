// Package portfwd — общий проброс портов с WAN NanoPi (DNAT) на хосты за ним.
//
// Данные: /opt/nanopi-edge/port-forwards.json (Store).
// nft:    /etc/nftables.d/nanopi-port-forwards.nft — одна таблица
// inet nanopi_portforward. Файл подключается из /etc/nftables.conf (загрузка
// при старте) и сам по себе идемпотентен: при изменении правил панель
// загружает только его (`nft -f`), атомарно заменяя одну таблицу. Таблицы
// sing-box и остальной ruleset не трогаются, sing-box не перезапускается.
package portfwd

import (
	"bufio"
	"bytes"
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
	"sync"
	"unicode/utf8"
)

const (
	DefaultStorePath     = "/opt/nanopi-edge/port-forwards.json"
	DefaultNftPath       = "/etc/nftables.d/nanopi-port-forwards.nft"
	DefaultNftConf       = "/etc/nftables.conf"
	DefaultEnvPath       = "/opt/nanopi-edge/.env"
	DefaultHomeRouteUnit = "/etc/systemd/system/nanopi-home-route.service"
	DefaultLanCIDR       = "10.10.10.0/24"
	TableName            = "nanopi_portforward"
	MaxRules             = 64
	MaxCommentLen        = 120

	// NPMComment — правила 80/443 с этим комментарием принадлежат странице
	// Nginx Proxy Manager (proxymgr). Общая страница показывает их, но
	// менять/удалять их нужно там.
	NPMComment = "nginx-proxy-manager"
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

// Store — WAN DNAT + опциональный маршрут/masquerade к LAN за CPE
// (когда dest вроде 192.168.1.137, а не хост на 10.10.10.0/24).
type Store struct {
	HomeNet string `json:"home_net,omitempty"` // 192.168.1.0/24
	HomeVia string `json:"home_via,omitempty"` // 10.10.10.179 — WAN роутера
	// RateLimit — ограничение новых подключений с одного внешнего IP.
	// Нет в файле (старый формат) — действуют значения по умолчанию.
	RateLimit *RateLimit `json:"rate_limit,omitempty"`
	Rules     []Rule     `json:"rules"`
}

// RateLimit — сколько НОВЫХ подключений в минуту принимать с одного внешнего
// IPv4 на все проброшенные порты вместе. Превышение отбрасывается и считается
// счётчиком; трафик из LAN и hairpin не ограничивается (только вход с WAN).
type RateLimit struct {
	Enabled   bool `json:"enabled"`
	PerMinute int  `json:"per_minute"`
	Burst     int  `json:"burst"`
	Log       bool `json:"log"`
}

const (
	// Щедро: Synology Photos/Drive открывают десятки соединений сразу,
	// а за мобильным CGNAT один внешний IP бывает у многих абонентов.
	DefaultRatePerMinute = 120
	DefaultRateBurst     = 240
	MinRatePerMinute     = 10
	MaxRatePerMinute     = 100000
	MaxRateBurst         = 100000
	// Лог превышений сам ограничен, чтобы не забить журнал.
	logRate = "6/minute burst 10 packets"
	// LogPrefix — префикс в журнале ядра (journalctl -k | grep nanopi-pf).
	LogPrefix = "nanopi-pf-ratelimit: "
)

// DefaultRateLimit — ограничение по умолчанию (включено).
func DefaultRateLimit() RateLimit {
	return RateLimit{Enabled: true, PerMinute: DefaultRatePerMinute, Burst: DefaultRateBurst, Log: true}
}

// Limit — действующее ограничение частоты.
func (s Store) Limit() RateLimit {
	if s.RateLimit == nil {
		return DefaultRateLimit()
	}
	return *s.RateLimit
}

// ValidateRateLimit проверяет порог и burst.
func ValidateRateLimit(rl RateLimit) error {
	if rl.PerMinute < MinRatePerMinute || rl.PerMinute > MaxRatePerMinute {
		return fmt.Errorf("порог: от %d до %d новых подключений в минуту", MinRatePerMinute, MaxRatePerMinute)
	}
	if rl.Burst < 1 || rl.Burst > MaxRateBurst {
		return fmt.Errorf("всплеск (burst): от 1 до %d подключений", MaxRateBurst)
	}
	return nil
}

// IsNPM — правило создано страницей Nginx Proxy Manager.
func IsNPM(r Rule) bool {
	return strings.EqualFold(strings.TrimSpace(r.Comment), NPMComment)
}

// Protos — фактические протоколы правила (both → tcp, udp).
func (r Rule) Protos() []string {
	if strings.EqualFold(r.Proto, "both") {
		return []string{"tcp", "udp"}
	}
	return []string{strings.ToLower(r.Proto)}
}

// ProtoLabel — подпись протокола для интерфейса.
func (r Rule) ProtoLabel() string {
	if strings.EqualFold(r.Proto, "both") {
		return "TCP+UDP"
	}
	return strings.ToUpper(r.Proto)
}

// Covers — правило занимает внешний порт port для протокола proto (tcp|udp).
func (r Rule) Covers(proto string, port int) bool {
	if r.WanPort != port {
		return false
	}
	for _, p := range r.Protos() {
		if p == proto {
			return true
		}
	}
	return false
}

// Describe — короткое описание правила для сообщений.
func (r Rule) Describe() string {
	s := fmt.Sprintf("%s %d → %s:%d", r.ProtoLabel(), r.WanPort, r.DestIP, r.DestPort)
	if r.Comment != "" {
		s += " («" + r.Comment + "»)"
	}
	return s
}

// --- окружение и внешние команды (подменяются в тестах) ---

var (
	mu sync.Mutex

	// runCmd выполняет внешнюю команду (nft, ip, systemctl).
	runCmd = func(name string, args ...string) ([]byte, error) {
		return exec.Command(name, args...).CombinedOutput()
	}
)

// SetCommandRunner подменяет запуск nft/ip/systemctl (для тестов других пакетов).
// Возвращает функцию восстановления.
func SetCommandRunner(fn func(name string, args ...string) ([]byte, error)) (restore func()) {
	mu.Lock()
	prev := runCmd
	runCmd = fn
	mu.Unlock()
	return func() {
		mu.Lock()
		runCmd = prev
		mu.Unlock()
	}
}

func StorePath() string   { return envOr("PORTFWD_STORE", DefaultStorePath) }
func NftPath() string     { return envOr("PORTFWD_NFT", DefaultNftPath) }
func NftConfPath() string { return envOr("PORTFWD_NFT_CONF", DefaultNftConf) }
func EnvPath() string     { return envOr("WEBUI_ENV", DefaultEnvPath) }
func HomeRouteUnitPath() string {
	return envOr("PORTFWD_HOME_ROUTE_UNIT", DefaultHomeRouteUnit)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// --- хранилище ---

func Load() (Store, error) {
	b, err := os.ReadFile(StorePath())
	if err != nil {
		if os.IsNotExist(err) {
			return Store{Rules: []Rule{}}, nil
		}
		return Store{}, err
	}
	var s Store
	if len(bytes.TrimSpace(b)) == 0 {
		return Store{Rules: []Rule{}}, nil
	}
	if err := json.Unmarshal(b, &s); err != nil {
		return Store{}, fmt.Errorf("port-forwards.json повреждён: %w", err)
	}
	if s.Rules == nil {
		s.Rules = []Rule{}
	}
	for i := range s.Rules {
		s.Rules[i].Proto = strings.ToLower(strings.TrimSpace(s.Rules[i].Proto))
	}
	return s, nil
}

func Save(s Store) error {
	if err := ValidateStore(s); err != nil {
		return err
	}
	if s.Rules == nil {
		s.Rules = []Rule{}
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	return atomicWrite(StorePath(), b, 0o644)
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
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

// --- валидация ---

func hasHomeRoute(s Store) bool {
	return strings.TrimSpace(s.HomeNet) != "" || strings.TrimSpace(s.HomeVia) != ""
}

// HasHomeRoute — задан маршрут в домашнюю сеть за роутером.
func HasHomeRoute(s Store) bool { return hasHomeRoute(s) }

func ValidateStore(s Store) error {
	if hasHomeRoute(s) {
		ip, n, err := net.ParseCIDR(strings.TrimSpace(s.HomeNet))
		if err != nil || n == nil || ip.To4() == nil {
			return fmt.Errorf("домашняя сеть: нужен IPv4 CIDR, например 192.168.1.0/24")
		}
		via := net.ParseIP(strings.TrimSpace(s.HomeVia))
		if via == nil || via.To4() == nil {
			return fmt.Errorf("WAN роутера: нужен IPv4-адрес, например 10.10.10.179")
		}
		if n.Contains(via) {
			return fmt.Errorf("WAN роутера %s не может быть внутри домашней сети %s", via, n)
		}
	}
	if s.RateLimit != nil {
		if err := ValidateRateLimit(*s.RateLimit); err != nil {
			return err
		}
	}
	if len(s.Rules) > MaxRules {
		return fmt.Errorf("слишком много правил (максимум %d)", MaxRules)
	}
	ids := map[string]struct{}{}
	for i, r := range s.Rules {
		if err := ValidateRule(r); err != nil {
			return fmt.Errorf("правило %d: %w", i+1, err)
		}
		if _, ok := ids[r.ID]; ok {
			return fmt.Errorf("правило %d: повторяется id %s", i+1, r.ID)
		}
		ids[r.ID] = struct{}{}
	}
	// Конфликты внешних портов — только среди включённых правил:
	// выключенное правило можно держать как «запасной» вариант.
	for i, a := range s.Rules {
		if !a.Enabled {
			continue
		}
		for _, b := range s.Rules[:i] {
			if !b.Enabled {
				continue
			}
			for _, p := range a.Protos() {
				if b.Covers(p, a.WanPort) {
					return fmt.Errorf("внешний порт %s %d уже занят правилом %s", strings.ToUpper(p), a.WanPort, b.Describe())
				}
			}
		}
	}
	return nil
}

func ValidateRule(r Rule) error {
	if r.ID == "" {
		return fmt.Errorf("пустой id")
	}
	if !validID(r.ID) {
		return fmt.Errorf("недопустимый id %q", r.ID)
	}
	switch strings.ToLower(strings.TrimSpace(r.Proto)) {
	case "tcp", "udp", "both":
	default:
		return fmt.Errorf("протокол: выберите tcp, udp или both")
	}
	if r.WanPort < 1 || r.WanPort > 65535 {
		return fmt.Errorf("внешний порт должен быть от 1 до 65535")
	}
	if r.DestPort < 1 || r.DestPort > 65535 {
		return fmt.Errorf("внутренний порт должен быть от 1 до 65535")
	}
	if err := validateDestIP(r.DestIP); err != nil {
		return err
	}
	if utf8.RuneCountInString(r.Comment) > MaxCommentLen {
		return fmt.Errorf("комментарий длиннее %d символов", MaxCommentLen)
	}
	if strings.ContainsAny(r.Comment, "\r\n") {
		return fmt.Errorf("комментарий должен быть в одну строку")
	}
	return nil
}

func validateDestIP(s string) error {
	ip := net.ParseIP(strings.TrimSpace(s))
	if ip == nil || ip.To4() == nil {
		return fmt.Errorf("внутренний IP: нужен IPv4-адрес, например 10.10.10.179")
	}
	ip4 := ip.To4()
	switch {
	case ip4.IsUnspecified(), ip4.IsLoopback(), ip4.IsMulticast(), ip4.Equal(net.IPv4bcast), ip4.IsLinkLocalUnicast():
		return fmt.Errorf("внутренний IP %s не подходит для проброса", ip4)
	}
	return nil
}

func validID(id string) bool {
	if len(id) > 32 {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {
			return false
		}
	}
	return true
}

// CounterNames — имена nft-счётчиков правила: новые подключения и трафик.
func CounterNames(id string) (conns, bytes string) {
	return "pf_" + id + "_new", "pf_" + id + "_bytes"
}

// DropCounter — счётчик отброшенных ограничением частоты.
const DropCounter = "pf_ratelimit_drop"

func NewID() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func NormalizeRule(r Rule) Rule {
	r.Proto = strings.ToLower(strings.TrimSpace(r.Proto))
	r.DestIP = strings.TrimSpace(r.DestIP)
	if ip := net.ParseIP(r.DestIP); ip != nil && ip.To4() != nil {
		r.DestIP = ip.To4().String()
	}
	r.Comment = strings.TrimSpace(sanitizeComment(r.Comment))
	r.ID = strings.TrimSpace(r.ID)
	if r.ID == "" {
		r.ID = NewID()
	}
	return r
}

// --- интерфейсы и сети ---

func readEnv() map[string]string {
	out := map[string]string{}
	f, err := os.Open(EnvPath())
	if err != nil {
		return out
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
		out[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"'`)
	}
	return out
}

// WanInterfaces — интерфейсы, с которых принимать DNAT (WAN ethernet, ppp0, VLAN).
func WanInterfaces() []string {
	env := readEnv()
	wan := "end0"
	if v := env["WAN_IF"]; v != "" {
		wan = v
	}
	out := []string{wan, "ppp0"}
	if vlan := env["PPPOE_VLAN"]; vlan != "" {
		if n, err := strconv.Atoi(vlan); err == nil && n >= 1 && n <= 4094 {
			out = append(out, fmt.Sprintf("%s.%d", wan, n))
		}
	}
	return out
}

// LanInterface — LAN NanoPi (к роутеру).
func LanInterface() string {
	if v := readEnv()["LAN_IF"]; v != "" {
		return v
	}
	return "enp1s0"
}

// LanCIDR — сеть LAN NanoPi (обычно 10.10.10.0/24).
func LanCIDR() string {
	out, err := runCmd("ip", "-4", "-o", "addr", "show", "dev", LanInterface())
	if err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			for i, f := range fields {
				if f == "inet" && i+1 < len(fields) {
					if _, n, err := net.ParseCIDR(fields[i+1]); err == nil && n.IP.To4() != nil {
						return n.String()
					}
				}
			}
		}
	}
	return DefaultLanCIDR
}

// DestHint — подсказка, как пакеты дойдут до адреса назначения.
// warn=true — скорее всего не дойдут без доп. настройки.
func DestHint(s Store, lanCIDR, destIP string) (hint string, warn bool) {
	ip := net.ParseIP(strings.TrimSpace(destIP))
	if ip == nil {
		return "", false
	}
	if _, n, err := net.ParseCIDR(lanCIDR); err == nil && n.Contains(ip) {
		return "в сети NanoPi", false
	}
	if hasHomeRoute(s) {
		if _, n, err := net.ParseCIDR(strings.TrimSpace(s.HomeNet)); err == nil && n.Contains(ip) {
			return "домашняя сеть через " + strings.TrimSpace(s.HomeVia), false
		}
	}
	return "адрес вне сети NanoPi " + lanCIDR + " и без маршрута — задайте «Маршрут в домашнюю сеть» ниже", true
}

// --- nft ---

// RenderNft строит содержимое /etc/nftables.d/nanopi-port-forwards.nft.
// Файл идемпотентен: `nft -f` на нём атомарно пересоздаёт только таблицу
// inet nanopi_portforward (add+delete+define в одной транзакции), так что
// его можно грузить и из nftables.conf после flush ruleset, и отдельно.
//
// Состав таблицы:
//   - named counters pf_<id>_new / pf_<id>_bytes на каждое включённое правило;
//   - chain ratelimit (filter, prerouting до DNAT): с WAN, ct state new,
//     только проброшенные порты — лимит на внешний IP, превышение в drop;
//   - chain prerouting (nat): DNAT, счётчик = новые подключения
//     (nat-цепочку проходит только первый пакет соединения);
//   - chain forward (filter): трафик проброшенных соединений в обе стороны;
//   - chain postrouting (nat): masquerade в домашнюю сеть за роутером.
func RenderNft(s Store, wanIfaces []string, lanIF string) string {
	var b strings.Builder
	b.WriteString("# Managed by nanopi-webui — port forwards (do not edit)\n")
	b.WriteString("# Применяется отдельно: nft -f этот_файл (меняет только эту таблицу).\n")
	fmt.Fprintf(&b, "add table inet %s\n", TableName)
	fmt.Fprintf(&b, "delete table inet %s\n", TableName)
	fmt.Fprintf(&b, "table inet %s {\n", TableName)
	if len(wanIfaces) == 0 {
		wanIfaces = []string{"end0", "ppp0"}
	}
	ifaceList := quoteIfaceSet(wanIfaces)

	var enabled []Rule
	ports := map[string][]int{}
	seenPort := map[string]map[int]bool{"tcp": {}, "udp": {}}
	for _, r := range s.Rules {
		if !r.Enabled {
			continue
		}
		enabled = append(enabled, r)
		for _, p := range r.Protos() {
			if !seenPort[p][r.WanPort] {
				seenPort[p][r.WanPort] = true
				ports[p] = append(ports[p], r.WanPort)
			}
		}
	}
	for _, r := range enabled {
		cn, cb := CounterNames(r.ID)
		fmt.Fprintf(&b, "\tcounter %s {\n\t}\n", cn)
		fmt.Fprintf(&b, "\tcounter %s {\n\t}\n", cb)
	}

	rl := s.Limit()
	if rl.Enabled && len(enabled) > 0 {
		fmt.Fprintf(&b, "\tcounter %s {\n\t}\n", DropCounter)
		b.WriteString("\tset ratelimit_src {\n")
		b.WriteString("\t\ttype ipv4_addr\n")
		b.WriteString("\t\tsize 65536\n")
		b.WriteString("\t\tflags dynamic,timeout\n")
		b.WriteString("\t\ttimeout 5m\n")
		b.WriteString("\t}\n")
		b.WriteString("\tchain ratelimit_drop {\n")
		if rl.Log {
			fmt.Fprintf(&b, "\t\tlimit rate %s log prefix %s level warn\n", logRate, strconv.Quote(LogPrefix))
		}
		b.WriteString("\t\tdrop\n")
		b.WriteString("\t}\n")
		b.WriteString("\tchain ratelimit {\n")
		// После conntrack (-200), до DNAT (-100).
		b.WriteString("\t\ttype filter hook prerouting priority -150; policy accept;\n")
		for _, p := range []string{"tcp", "udp"} {
			if len(ports[p]) == 0 {
				continue
			}
			fmt.Fprintf(&b,
				"\t\tiifname { %s } meta nfproto ipv4 ct state new %s dport { %s } update @ratelimit_src { ip saddr limit rate over %d/minute burst %d packets } counter name %s jump ratelimit_drop\n",
				ifaceList, p, joinInts(ports[p]), rl.PerMinute, rl.Burst, strconv.Quote(DropCounter),
			)
		}
		b.WriteString("\t}\n")
	}

	b.WriteString("\tchain prerouting {\n")
	b.WriteString("\t\ttype nat hook prerouting priority dstnat; policy accept;\n")
	for _, r := range enabled {
		comment := ""
		if r.Comment != "" {
			comment = " # " + sanitizeComment(r.Comment)
		}
		cn, _ := CounterNames(r.ID)
		for _, p := range r.Protos() {
			fmt.Fprintf(&b,
				"\t\tiifname { %s } %s dport %d counter name %s dnat ip to %s:%d%s\n",
				ifaceList, p, r.WanPort, strconv.Quote(cn), r.DestIP, r.DestPort, comment,
			)
		}
	}
	b.WriteString("\t}\n")

	if len(enabled) > 0 {
		b.WriteString("\tchain forward {\n")
		b.WriteString("\t\ttype filter hook forward priority filter - 5; policy accept;\n")
		for _, r := range enabled {
			_, cb := CounterNames(r.ID)
			for _, p := range r.Protos() {
				fmt.Fprintf(&b,
					"\t\tct status dnat ct original protocol %s ct original proto-dst %d ct reply ip saddr %s ct reply proto-src %d counter name %s\n",
					p, r.WanPort, r.DestIP, r.DestPort, strconv.Quote(cb),
				)
			}
		}
		b.WriteString("\t}\n")
	}

	// SNAT к LAN за CPE — чтобы ответы из домашней сети шли обратно через NanoPi.
	if hasHomeRoute(s) && lanIF != "" {
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

func joinInts(v []int) string {
	parts := make([]string, len(v))
	for i, n := range v {
		parts[i] = strconv.Itoa(n)
	}
	return strings.Join(parts, ", ")
}

// Counter — значение nft-счётчика.
type Counter struct {
	Packets uint64 `json:"packets"`
	Bytes   uint64 `json:"bytes"`
}

// Counters читает именованные счётчики таблицы проброса
// (nft -j list table inet nanopi_portforward). Счётчики живут с момента
// последнего применения правил или загрузки платы.
func Counters() (map[string]Counter, error) {
	out, err := runCmd("nft", "-j", "list", "table", "inet", TableName)
	if err != nil {
		return nil, nftErr("nft list table", out, err)
	}
	return parseCounters(out)
}

func parseCounters(data []byte) (map[string]Counter, error) {
	var doc struct {
		Nftables []map[string]json.RawMessage `json:"nftables"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("nft -j: %w", err)
	}
	res := map[string]Counter{}
	for _, item := range doc.Nftables {
		raw, ok := item["counter"]
		if !ok {
			continue
		}
		var c struct {
			Name    string `json:"name"`
			Table   string `json:"table"`
			Packets uint64 `json:"packets"`
			Bytes   uint64 `json:"bytes"`
		}
		if err := json.Unmarshal(raw, &c); err != nil || c.Name == "" {
			continue
		}
		if c.Table != "" && c.Table != TableName {
			continue
		}
		res[c.Name] = Counter{Packets: c.Packets, Bytes: c.Bytes}
	}
	return res, nil
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

// EnsureNftInclude — nftables.conf должен подключать файл правил, чтобы
// проброс восстановился после перезагрузки. Сам nftables.conf не перегружается.
func EnsureNftInclude(confPath string) error {
	b, err := os.ReadFile(confPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("нет %s — сначала router-on", confPath)
		}
		return err
	}
	if strings.Contains(string(b), "nanopi-port-forwards.nft") {
		return nil
	}
	f, err := os.OpenFile(confPath, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString("\ninclude \"" + DefaultNftPath + "\"\n")
	return err
}

func nftErr(op string, out []byte, err error) error {
	msg := strings.TrimSpace(string(out))
	if msg == "" {
		return fmt.Errorf("%s: %w", op, err)
	}
	return fmt.Errorf("%s: %w\n%s", op, err, msg)
}

// --- маршрут в домашнюю сеть ---

func homeRouteUnitBody(netCIDR, via, lan string) string {
	return fmt.Sprintf(`[Unit]
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
}

// syncHomeRoute приводит маршрут и unit к new; снимает старый маршрут, если он изменился.
func syncHomeRoute(old, cur Store) error {
	lan := LanInterface()
	unit := HomeRouteUnitPath()
	oldNet, oldVia := strings.TrimSpace(old.HomeNet), strings.TrimSpace(old.HomeVia)
	newNet, newVia := strings.TrimSpace(cur.HomeNet), strings.TrimSpace(cur.HomeVia)

	if hasHomeRoute(old) && (oldNet != newNet || oldVia != newVia) && oldNet != "" {
		_, _ = runCmd("ip", "route", "del", oldNet, "via", oldVia, "dev", lan)
	}
	if !hasHomeRoute(cur) {
		if _, err := os.Stat(unit); err == nil {
			_, _ = runCmd("systemctl", "disable", "nanopi-home-route.service")
			_ = os.Remove(unit)
			_, _ = runCmd("systemctl", "daemon-reload")
		}
		return nil
	}
	if out, err := runCmd("ip", "route", "replace", newNet, "via", newVia, "dev", lan); err != nil {
		return fmt.Errorf("маршрут %s via %s: %w (%s)", newNet, newVia, err, strings.TrimSpace(string(out)))
	}
	body := homeRouteUnitBody(newNet, newVia, lan)
	if prev, err := os.ReadFile(unit); err == nil && string(prev) == body {
		return nil
	}
	if err := atomicWrite(unit, []byte(body), 0o644); err != nil {
		return err
	}
	_, _ = runCmd("systemctl", "daemon-reload")
	if out, err := runCmd("systemctl", "enable", "nanopi-home-route.service"); err != nil {
		return fmt.Errorf("enable nanopi-home-route: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// --- применение ---

// commit проверяет новое состояние в nft, сохраняет его и атомарно
// загружает только таблицу проброса. При ошибке загрузки откатывает файлы.
func commit(old, cur Store) error {
	if cur.Rules == nil {
		cur.Rules = []Rule{}
	}
	if err := ValidateStore(cur); err != nil {
		return err
	}
	nftPath := NftPath()
	content := RenderNft(cur, WanInterfaces(), LanInterface())
	if err := os.MkdirAll(filepath.Dir(nftPath), 0o755); err != nil {
		return err
	}
	// 1. Проверка синтаксиса и ссылок без применения.
	tmp, err := os.CreateTemp(filepath.Dir(nftPath), ".nft-check-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.WriteString(content); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if out, err := runCmd("nft", "-c", "-f", tmpPath); err != nil {
		return nftErr("nft отклонил правила (ничего не применено)", out, err)
	}

	prevJSON, prevJSONErr := os.ReadFile(StorePath())
	prevNft, prevNftErr := os.ReadFile(nftPath)
	rollback := func() {
		if prevJSONErr == nil {
			_ = atomicWrite(StorePath(), prevJSON, 0o644)
		} else {
			_ = os.Remove(StorePath())
		}
		if prevNftErr == nil {
			_ = atomicWrite(nftPath, prevNft, 0o644)
		}
	}

	// 2. Сохранить JSON и nft-файл (для загрузки при старте).
	if err := Save(cur); err != nil {
		return err
	}
	if err := atomicWrite(nftPath, []byte(content), 0o644); err != nil {
		rollback()
		return err
	}
	if err := EnsureNftInclude(NftConfPath()); err != nil {
		rollback()
		return err
	}
	// 3. Маршрут до LAN за CPE (до DNAT, чтобы пакеты сразу знали путь).
	if err := syncHomeRoute(old, cur); err != nil {
		rollback()
		_ = syncHomeRoute(cur, old)
		return err
	}
	// 4. Атомарно заменить только таблицу проброса.
	if out, err := runCmd("nft", "-f", nftPath); err != nil {
		rollback()
		_ = syncHomeRoute(cur, old)
		return nftErr("nft -f "+nftPath, out, err)
	}
	return nil
}

func cloneStore(s Store) Store {
	c := s
	c.Rules = append([]Rule(nil), s.Rules...)
	if c.Rules == nil {
		c.Rules = []Rule{}
	}
	return c
}

// Mutate — единственная точка изменения: загрузить, изменить, проверить,
// сохранить и применить. Вызовы сериализуются.
func Mutate(fn func(s *Store) error) (Store, error) {
	mu.Lock()
	defer mu.Unlock()
	old, err := Load()
	if err != nil {
		return old, err
	}
	cur := cloneStore(old)
	if err := fn(&cur); err != nil {
		return old, err
	}
	if err := commit(old, cur); err != nil {
		return old, err
	}
	return cur, nil
}

// Reapply — заново записать и загрузить текущие правила (например, после
// смены WAN-интерфейса).
func Reapply() (Store, error) {
	return Mutate(func(*Store) error { return nil })
}

// Apply — сохранить s целиком и применить (совместимость).
func Apply(s Store, _ bool) error {
	_, err := Mutate(func(cur *Store) error {
		*cur = cloneStore(s)
		return nil
	})
	return err
}

// SetHomeRoute обновляет маршрут к LAN за CPE и применяет.
// Пустые оба поля — маршрут снять.
func SetHomeRoute(homeNet, homeVia string) (Store, error) {
	homeNet = strings.TrimSpace(homeNet)
	homeVia = strings.TrimSpace(homeVia)
	if (homeNet == "") != (homeVia == "") {
		return Store{}, fmt.Errorf("заполните оба поля — домашнюю сеть и WAN роутера — или очистите оба, чтобы снять маршрут")
	}
	return Mutate(func(s *Store) error {
		if homeNet == "" && homeVia == "" {
			s.HomeNet, s.HomeVia = "", ""
			return nil
		}
		ip, n, err := net.ParseCIDR(homeNet)
		if err != nil || ip.To4() == nil {
			return fmt.Errorf("домашняя сеть: нужен IPv4 CIDR, например 192.168.1.0/24")
		}
		via := net.ParseIP(homeVia)
		if via == nil || via.To4() == nil {
			return fmt.Errorf("WAN роутера: нужен IPv4-адрес, например 10.10.10.179")
		}
		lan := LanCIDR()
		if _, ln, err := net.ParseCIDR(lan); err == nil {
			if !ln.Contains(via) {
				return fmt.Errorf("WAN роутера %s должен быть в сети NanoPi %s", via, lan)
			}
			if ln.Contains(n.IP) || n.Contains(ln.IP) {
				return fmt.Errorf("домашняя сеть %s пересекается с сетью NanoPi %s", n, lan)
			}
		}
		s.HomeNet = n.String()
		s.HomeVia = via.To4().String()
		return nil
	})
}

func findRule(s *Store, id string) (int, error) {
	id = strings.TrimSpace(id)
	for i := range s.Rules {
		if s.Rules[i].ID == id {
			return i, nil
		}
	}
	return -1, fmt.Errorf("правило не найдено — обновите страницу")
}

func errManaged(r Rule) error {
	return fmt.Errorf("правило %s управляется страницей «Nginx Proxy Manager» — меняйте его там", r.Describe())
}

func checkUserComment(r Rule) error {
	if IsNPM(r) {
		return fmt.Errorf("комментарий «%s» зарезервирован для страницы Nginx Proxy Manager", NPMComment)
	}
	return nil
}

// Add добавляет включённое правило.
func Add(r Rule) (Store, error) {
	r.ID = ""
	r = NormalizeRule(r)
	r.Enabled = true
	if err := ValidateRule(r); err != nil {
		return Store{}, err
	}
	if err := checkUserComment(r); err != nil {
		return Store{}, err
	}
	return Mutate(func(s *Store) error {
		s.Rules = append(s.Rules, r)
		return nil
	})
}

// Update меняет протокол/порты/адрес/комментарий правила (Enabled сохраняется).
func Update(r Rule) (Store, error) {
	if strings.TrimSpace(r.ID) == "" {
		return Store{}, fmt.Errorf("правило не найдено — обновите страницу")
	}
	r = NormalizeRule(r)
	if err := ValidateRule(r); err != nil {
		return Store{}, err
	}
	if err := checkUserComment(r); err != nil {
		return Store{}, err
	}
	return Mutate(func(s *Store) error {
		i, err := findRule(s, r.ID)
		if err != nil {
			return err
		}
		if IsNPM(s.Rules[i]) {
			return errManaged(s.Rules[i])
		}
		r.Enabled = s.Rules[i].Enabled
		s.Rules[i] = r
		return nil
	})
}

func Delete(id string) (Store, error) {
	return Mutate(func(s *Store) error {
		i, err := findRule(s, id)
		if err != nil {
			return err
		}
		if IsNPM(s.Rules[i]) {
			return errManaged(s.Rules[i])
		}
		s.Rules = append(s.Rules[:i], s.Rules[i+1:]...)
		return nil
	})
}

func SetEnabled(id string, enabled bool) (Store, error) {
	return Mutate(func(s *Store) error {
		i, err := findRule(s, id)
		if err != nil {
			return err
		}
		if IsNPM(s.Rules[i]) {
			return errManaged(s.Rules[i])
		}
		s.Rules[i].Enabled = enabled
		return nil
	})
}

// SetRateLimit сохраняет ограничение частоты новых подключений и применяет.
func SetRateLimit(rl RateLimit) (Store, error) {
	if err := ValidateRateLimit(rl); err != nil {
		return Store{}, err
	}
	return Mutate(func(s *Store) error {
		v := rl
		s.RateLimit = &v
		return nil
	})
}

// Reconcile приводит nft-файл к текущему port-forwards.json при старте панели:
// после обновления панели (новый формат файла, счётчики, ограничение частоты)
// или смены WAN-интерфейса правила применяются без ручных действий.
// Нет port-forwards.json — ничего не делает. Совпадает — ничего не делает.
func Reconcile() (changed bool, err error) {
	if _, err := os.Stat(StorePath()); err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	s, err := Load()
	if err != nil {
		return false, err
	}
	want := RenderNft(s, WanInterfaces(), LanInterface())
	if cur, err := os.ReadFile(NftPath()); err == nil && string(cur) == want {
		return false, nil
	}
	if _, err := Reapply(); err != nil {
		return false, err
	}
	return true, nil
}
