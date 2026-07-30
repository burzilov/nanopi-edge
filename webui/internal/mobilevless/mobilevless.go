// Package mobilevless управляет одним входящим VLESS+Reality для мобильного Hiddify.
package mobilevless

import (
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"nanopi-webui/internal/hairpin"
	"nanopi-webui/internal/sysd"
)

const (
	DefaultStatePath = "/etc/sing-box/inbound-vless-reality.json"
	DefaultConfigPath = "/etc/sing-box/config.json"
	InboundTag       = "vless-mobile"
	DefaultPort      = 8443
	DefaultHSPort    = 443
	Flow             = "xtls-rprx-vision"
	Fingerprint      = "chrome"
)

// State — единственный файл 0600 с секретами и параметрами inbound.
type State struct {
	Enabled         bool   `json:"enabled"`
	Port            int    `json:"port"`
	UUID            string `json:"uuid,omitempty"`
	PrivateKey      string `json:"private_key,omitempty"`
	PublicKey       string `json:"public_key,omitempty"`
	ShortID         string `json:"short_id,omitempty"`
	HandshakeServer string `json:"handshake_server"`
	HandshakePort   int    `json:"handshake_port"`
	ServerName      string `json:"server_name"`
	Label           string `json:"label,omitempty"`
	CreatedAt       string `json:"created_at,omitempty"`
}

// Settings — публичные поля формы (без секретов).
type Settings struct {
	Port            int    `json:"port"`
	HandshakeServer string `json:"handshake_server"`
	HandshakePort   int    `json:"handshake_port"`
	ServerName      string `json:"server_name"`
	Label           string `json:"label,omitempty"`
}

// Status — несекретное состояние для страницы и API.
type Status struct {
	Enabled         bool     `json:"enabled"`
	HasProfile      bool     `json:"has_profile"`
	Configured      bool     `json:"configured"`
	ProfileActive   bool     `json:"profile_active"`
	Port            int      `json:"port"`
	ListenOK        bool     `json:"listen_ok"`
	ServiceActive   bool     `json:"service_active"`
	WanIP           string   `json:"wan_ip"`
	WanIPs          []string `json:"wan_ips"`
	HandshakeServer string   `json:"handshake_server"`
	HandshakePort   int      `json:"handshake_port"`
	ServerName      string   `json:"server_name"`
	Label           string   `json:"label,omitempty"`
	CreatedAt       string   `json:"created_at,omitempty"`
	InboundPresent  bool     `json:"inbound_present"`
	SiteReady       bool     `json:"site_ready"`
	Hint            string   `json:"hint,omitempty"`
}

// Profile — одноразовая выдача URI (содержит секреты).
type Profile struct {
	URI     string `json:"uri"`
	WanIP   string `json:"wan_ip"`
	Port    int    `json:"port"`
	Label   string `json:"label,omitempty"`
	SNI     string `json:"sni"`
	ShortID string `json:"short_id"`
	QRPNG  string `json:"-"` // data URI PNG для <img>
}

// HandshakeCheck — результат проверки маскировочного TLS-сайта.
type HandshakeCheck struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
	Server  string `json:"server"`
	Port    int    `json:"port"`
	SNI     string `json:"sni"`
}

// Preset — стартовый кандидат Reality (проверяется перед использованием).
type Preset struct {
	Name   string `json:"name"`
	Server string `json:"server"`
	Port   int    `json:"port"`
	SNI    string `json:"sni"`
}

func Presets() []Preset {
	return []Preset{
		{Name: "www.cloudflare.com", Server: "www.cloudflare.com", Port: 443, SNI: "www.cloudflare.com"},
		{Name: "www.microsoft.com", Server: "www.microsoft.com", Port: 443, SNI: "www.microsoft.com"},
		{Name: "www.samsung.com", Server: "www.samsung.com", Port: 443, SNI: "www.samsung.com"},
		{Name: "dl.google.com", Server: "dl.google.com", Port: 443, SNI: "dl.google.com"},
	}
}

func StatePath() string {
	if v := os.Getenv("VLESS_MOBILE_STATE"); v != "" {
		return v
	}
	return DefaultStatePath
}

func ConfigPath() string {
	if v := os.Getenv("SINGBOX_CONFIG"); v != "" {
		return v
	}
	return DefaultConfigPath
}

func UnitName() string {
	if v := os.Getenv("SINGBOX_UNIT"); v != "" {
		return v
	}
	return "sing-box"
}

func Load() (State, error) {
	b, err := os.ReadFile(StatePath())
	if err != nil {
		if os.IsNotExist(err) {
			return State{Port: DefaultPort, HandshakePort: DefaultHSPort}, nil
		}
		return State{}, err
	}
	var st State
	if err := json.Unmarshal(b, &st); err != nil {
		return State{}, fmt.Errorf("inbound-vless-reality.json: %w", err)
	}
	if st.Port == 0 {
		st.Port = DefaultPort
	}
	if st.HandshakePort == 0 {
		st.HandshakePort = DefaultHSPort
	}
	return st, nil
}

func saveState(st State) error {
	path := StatePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	return atomicWrite(path, b, 0o600)
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
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

func ValidateSettings(s Settings) error {
	if s.Port < 1 || s.Port > 65535 {
		return fmt.Errorf("порт должен быть 1..65535")
	}
	if s.Port == 80 || s.Port == 443 {
		return fmt.Errorf("порты 80 и 443 заняты Nginx Proxy Manager — выберите другой, например 8443")
	}
	s.HandshakeServer = strings.TrimSpace(s.HandshakeServer)
	s.ServerName = strings.TrimSpace(s.ServerName)
	if s.HandshakeServer == "" {
		return fmt.Errorf("укажите маскировочный TLS-сайт (handshake server)")
	}
	if s.ServerName == "" {
		return fmt.Errorf("укажите SNI (server_name)")
	}
	if s.HandshakePort < 1 || s.HandshakePort > 65535 {
		return fmt.Errorf("порт маскировочного сайта должен быть 1..65535")
	}
	return nil
}

func GetStatus() (Status, error) {
	st, err := Load()
	if err != nil {
		return Status{}, err
	}
	wan := hairpin.WanIPv4s()
	wanIP := ""
	if len(wan) > 0 {
		wanIP = wan[0]
	}
	hasProfile := st.UUID != "" && st.PrivateKey != "" && st.PublicKey != ""
	siteReady := strings.TrimSpace(st.HandshakeServer) != "" && strings.TrimSpace(st.ServerName) != ""
	out := Status{
		Enabled:         st.Enabled,
		HasProfile:      hasProfile,
		Configured:      hasProfile,
		ProfileActive:   st.Enabled && hasProfile && siteReady,
		Port:            st.Port,
		ServiceActive:   sysd.IsActive(UnitName()) == "active",
		WanIP:           wanIP,
		WanIPs:          wan,
		HandshakeServer: st.HandshakeServer,
		HandshakePort:   st.HandshakePort,
		ServerName:      st.ServerName,
		Label:           st.Label,
		CreatedAt:       st.CreatedAt,
		SiteReady:       siteReady,
		ListenOK:        st.Enabled && portListening(st.Port),
	}
	if b, err := os.ReadFile(ConfigPath()); err == nil {
		out.InboundPresent = HasInbound(b)
	}
	if out.Enabled && !out.InboundPresent {
		out.Hint = "Включено в состоянии, но inbound vless-mobile отсутствует в config.json — сохраните маскировочный сайт заново."
	}
	if !out.HasProfile {
		out.Hint = "Сначала создайте профиль (метка и порт), затем выберите маскировочный TLS-сайт."
	} else if out.HasProfile && !out.SiteReady {
		out.Hint = "Профиль есть. Выберите и проверьте маскировочный сайт, затем нажмите «Сохранить и включить»."
	} else if out.WanIP == "" {
		if out.Hint != "" {
			out.Hint += " "
		}
		out.Hint += "Публичный WAN IPv4 пока не найден — URI нельзя выдать."
	}
	return out, nil
}

func portListening(port int) bool {
	if port < 1 {
		return false
	}
	cmd := exec.Command("ss", "-ltn")
	b, err := cmd.Output()
	if err != nil {
		return false
	}
	needle := ":" + strconv.Itoa(port)
	for _, line := range strings.Split(string(b), "\n") {
		if strings.Contains(line, needle) && strings.Contains(line, "LISTEN") {
			return true
		}
	}
	return false
}

func waitListening(port int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if portListening(port) {
			return true
		}
		time.Sleep(250 * time.Millisecond)
	}
	return portListening(port)
}

// CheckHandshake проверяет DNS, TCP и TLS к маскировочному сайту.
func CheckHandshake(server string, port int, sni string) HandshakeCheck {
	server = strings.TrimSpace(server)
	sni = strings.TrimSpace(sni)
	if sni == "" {
		sni = server
	}
	if port < 1 {
		port = DefaultHSPort
	}
	res := HandshakeCheck{Server: server, Port: port, SNI: sni}
	if server == "" {
		res.Message = "пустой адрес сайта"
		return res
	}
	ips, err := net.LookupIP(server)
	if err != nil || len(ips) == 0 {
		res.Message = "DNS не резолвится: " + errString(err)
		return res
	}
	addr := net.JoinHostPort(server, strconv.Itoa(port))
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		res.Message = "TCP недоступен: " + err.Error()
		return res
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
	tlsConn := tls.Client(conn, &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: false,
		MinVersion:         tls.VersionTLS12,
	})
	if err := tlsConn.Handshake(); err != nil {
		res.Message = "TLS handshake не удался: " + err.Error()
		return res
	}
	_ = tlsConn.Close()
	res.OK = true
	res.Message = "OK: DNS, TCP и TLS с SNI «" + sni + "»"
	return res
}

func errString(err error) string {
	if err == nil {
		return "нет A/AAAA"
	}
	return err.Error()
}

// SaveAndEnable сохраняет маскировочный сайт/порт и включает inbound (профиль уже должен быть).
func SaveAndEnable(s Settings, createProfileIfMissing bool) error {
	if err := ValidateSettings(s); err != nil {
		return err
	}
	check := CheckHandshake(s.HandshakeServer, s.HandshakePort, s.ServerName)
	if !check.OK {
		return fmt.Errorf("проверка маскировочного сайта: %s", check.Message)
	}
	st, err := Load()
	if err != nil {
		return err
	}
	if st.UUID == "" || st.PrivateKey == "" || st.PublicKey == "" {
		if createProfileIfMissing {
			return fmt.Errorf("сначала создайте профиль")
		}
		return fmt.Errorf("профиль ещё не создан — сначала шаг «Создать профиль»")
	}
	st.Enabled = true
	st.Port = s.Port
	st.HandshakeServer = strings.TrimSpace(s.HandshakeServer)
	st.HandshakePort = s.HandshakePort
	st.ServerName = strings.TrimSpace(s.ServerName)
	if err := applyConfig(st); err != nil {
		return err
	}
	if err := saveState(st); err != nil {
		return err
	}
	_ = waitListening(st.Port, 8*time.Second)
	return nil
}

// CreateProfile создаёт ключи и UUID без включения inbound (сайт настраивается отдельно).
func CreateProfile(port int, label string) error {
	if port < 1 || port > 65535 {
		return fmt.Errorf("порт должен быть 1..65535")
	}
	if port == 80 || port == 443 {
		return fmt.Errorf("порты 80 и 443 заняты Nginx Proxy Manager — выберите другой, например 8443")
	}
	st, err := Load()
	if err != nil {
		return err
	}
	if st.UUID != "" && st.PrivateKey != "" {
		return fmt.Errorf("профиль уже есть — используйте «Перевыпустить» или «Отозвать»")
	}
	label = strings.TrimSpace(label)
	if label == "" {
		label = "mobile"
	}
	priv, pub, err := generateRealityKeypair()
	if err != nil {
		return err
	}
	uuid, err := generateUUID()
	if err != nil {
		return err
	}
	sid, err := generateShortID()
	if err != nil {
		return err
	}
	st.Enabled = false
	st.Port = port
	st.Label = label
	st.PrivateKey = priv
	st.PublicKey = pub
	st.UUID = uuid
	st.ShortID = sid
	st.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	// сайт ещё не выбран — inbound не поднимаем
	st.HandshakeServer = ""
	st.HandshakePort = DefaultHSPort
	st.ServerName = ""
	return saveState(st)
}

// RotateProfile меняет UUID и short_id, сохраняя Reality-ключи и маскировку.
func RotateProfile() error {
	st, err := Load()
	if err != nil {
		return err
	}
	if st.PrivateKey == "" || st.UUID == "" {
		return fmt.Errorf("сначала создайте профиль")
	}
	uuid, err := generateUUID()
	if err != nil {
		return err
	}
	sid, err := generateShortID()
	if err != nil {
		return err
	}
	st.UUID = uuid
	st.ShortID = sid
	st.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	if st.Enabled && st.HandshakeServer != "" && st.ServerName != "" {
		if err := applyConfig(st); err != nil {
			return err
		}
		_ = waitListening(st.Port, 8*time.Second)
	}
	return saveState(st)
}

// Revoke удаляет inbound из config.json и очищает UUID/short_id (ключи Reality сохраняются).
func Revoke() error {
	st, err := Load()
	if err != nil {
		return err
	}
	st.Enabled = false
	st.UUID = ""
	st.ShortID = ""
	st.CreatedAt = ""
	if err := removeInbound(); err != nil {
		return err
	}
	return saveState(st)
}

// ShowProfile выдаёт URI только если профиль активен.
func ShowProfile() (Profile, error) {
	st, err := Load()
	if err != nil {
		return Profile{}, err
	}
	if !st.Enabled || st.UUID == "" || st.PublicKey == "" {
		return Profile{}, fmt.Errorf("нет активного профиля")
	}
	if strings.TrimSpace(st.ServerName) == "" || strings.TrimSpace(st.HandshakeServer) == "" {
		return Profile{}, fmt.Errorf("сначала сохраните маскировочный сайт")
	}
	wan := hairpin.WanIPv4s()
	if len(wan) == 0 {
		return Profile{}, fmt.Errorf("нет публичного WAN IPv4")
	}
	uri := BuildURI(st, wan[0])
	png, err := QRDataURI(uri)
	if err != nil {
		return Profile{}, fmt.Errorf("QR: %w", err)
	}
	return Profile{
		URI:     uri,
		WanIP:   wan[0],
		Port:    st.Port,
		Label:   st.Label,
		SNI:     st.ServerName,
		ShortID: st.ShortID,
		QRPNG:   png,
	}, nil
}

func BuildURI(st State, host string) string {
	q := url.Values{}
	q.Set("encryption", "none")
	q.Set("flow", Flow)
	q.Set("security", "reality")
	q.Set("sni", st.ServerName)
	q.Set("fp", Fingerprint)
	q.Set("pbk", st.PublicKey)
	q.Set("sid", st.ShortID)
	q.Set("type", "tcp")
	q.Set("headerType", "none")
	name := st.Label
	if name == "" {
		name = "nanopi-mobile"
	}
	return fmt.Sprintf("vless://%s@%s:%d?%s#%s",
		st.UUID, host, st.Port, q.Encode(), url.QueryEscape(name))
}

func BuildInbound(st State) map[string]any {
	return map[string]any{
		"type":        "vless",
		"tag":         InboundTag,
		"listen":      "0.0.0.0",
		"listen_port": st.Port,
		"users": []any{
			map[string]any{
				"uuid": st.UUID,
				"flow": Flow,
			},
		},
		"tls": map[string]any{
			"enabled":     true,
			"server_name": st.ServerName,
			"reality": map[string]any{
				"enabled": true,
				"handshake": map[string]any{
					"server":      st.HandshakeServer,
					"server_port": st.HandshakePort,
				},
				"private_key": st.PrivateKey,
				"short_id":    []any{st.ShortID},
			},
		},
	}
}

func HasInbound(configJSON []byte) bool {
	var root map[string]any
	if err := json.Unmarshal(configJSON, &root); err != nil {
		return false
	}
	_, idx, err := findInbound(root)
	return err == nil && idx >= 0
}

// MergeInbound вставляет или заменяет inbound vless-mobile. Если enabled=false или нет UUID — удаляет.
func MergeInbound(configJSON []byte, st State) ([]byte, error) {
	var root map[string]any
	if err := json.Unmarshal(configJSON, &root); err != nil {
		return nil, err
	}
	inbounds, _ := root["inbounds"].([]any)
	if inbounds == nil {
		inbounds = []any{}
	}
	filtered := make([]any, 0, len(inbounds))
	for _, raw := range inbounds {
		ob, ok := raw.(map[string]any)
		if !ok {
			filtered = append(filtered, raw)
			continue
		}
		if ob["tag"] == InboundTag {
			continue
		}
		filtered = append(filtered, raw)
	}
	if st.Enabled && st.UUID != "" && st.PrivateKey != "" && st.ShortID != "" {
		// конфликт порта с другим inbound
		for _, raw := range filtered {
			ob, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if lp, ok := asInt(ob["listen_port"]); ok && lp == st.Port {
				return nil, fmt.Errorf("порт %d уже занят другим inbound (%v)", st.Port, ob["tag"])
			}
		}
		filtered = append(filtered, BuildInbound(st))
	}
	root["inbounds"] = filtered
	out, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return nil, err
	}
	out = append(out, '\n')
	return out, nil
}

func findInbound(root map[string]any) ([]any, int, error) {
	inbounds, ok := root["inbounds"].([]any)
	if !ok {
		return nil, -1, fmt.Errorf("нет inbounds")
	}
	idx := -1
	count := 0
	for i, raw := range inbounds {
		ob, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if ob["tag"] == InboundTag {
			count++
			idx = i
		}
	}
	if count > 1 {
		return inbounds, -1, fmt.Errorf("найдено несколько inbound с tag %q", InboundTag)
	}
	return inbounds, idx, nil
}

func asInt(v any) (int, bool) {
	switch t := v.(type) {
	case float64:
		return int(t), true
	case int:
		return t, true
	case json.Number:
		i, err := t.Int64()
		return int(i), err == nil
	case string:
		i, err := strconv.Atoi(t)
		return i, err == nil
	default:
		return 0, false
	}
}

func applyConfig(st State) error {
	cfgPath := ConfigPath()
	b, err := os.ReadFile(cfgPath)
	if err != nil {
		return err
	}
	merged, err := MergeInbound(b, st)
	if err != nil {
		return err
	}
	return writeCheckedConfig(cfgPath, merged)
}

func removeInbound() error {
	cfgPath := ConfigPath()
	b, err := os.ReadFile(cfgPath)
	if err != nil {
		return err
	}
	st := State{Enabled: false}
	merged, err := MergeInbound(b, st)
	if err != nil {
		return err
	}
	return writeCheckedConfig(cfgPath, merged)
}

func writeCheckedConfig(cfgPath string, content []byte) error {
	dir := filepath.Dir(cfgPath)
	tmp, err := os.CreateTemp(dir, "singbox-check-*.json")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(content); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	_ = tmp.Chmod(0o600)
	_ = tmp.Close()
	defer os.Remove(tmpPath)

	out, err := sysd.SingboxCheck(tmpPath)
	if err != nil {
		return fmt.Errorf("sing-box check: %w (%s)", err, strings.TrimSpace(out))
	}

	bak := cfgPath + ".bak." + time.Now().Format("20060102150405")
	if cur, err := os.ReadFile(cfgPath); err == nil {
		_ = os.WriteFile(bak, cur, 0o600)
	}

	if err := atomicWrite(cfgPath, content, 0o600); err != nil {
		return err
	}
	if err := sysd.Restart(UnitName()); err != nil {
		// откат
		if cur, rerr := os.ReadFile(bak); rerr == nil {
			_ = atomicWrite(cfgPath, cur, 0o600)
			_ = sysd.Restart(UnitName())
		}
		return err
	}
	sysd.WaitActive(UnitName(), 15*time.Second)
	return nil
}

// ReapplyFromState применяется после пересборки config.json установщиком.
func ReapplyFromState() error {
	st, err := Load()
	if err != nil {
		return err
	}
	if !st.Enabled || st.UUID == "" || st.PrivateKey == "" {
		return nil
	}
	return applyConfig(st)
}

// WarnIfInboundMissing проверяет ручное сохранение config: inbound пропал, а state включён.
func WarnIfInboundMissing(configJSON []byte) string {
	st, err := Load()
	if err != nil || !st.Enabled || st.UUID == "" {
		return ""
	}
	if !HasInbound(configJSON) {
		return "Внимание: inbound «vless-mobile» отсутствует в конфиге, но профиль мобильного VLESS включён. Сохраните настройки на странице «Мобильный VLESS» или отзовите профиль."
	}
	return ""
}

var keyLineRe = regexp.MustCompile(`(?i)(PrivateKey|PublicKey)\s*:\s*(\S+)`)

func generateRealityKeypair() (priv, pub string, err error) {
	cmd := exec.Command("sing-box", "generate", "reality-keypair")
	b, err := cmd.CombinedOutput()
	if err != nil {
		return "", "", fmt.Errorf("sing-box generate reality-keypair: %w (%s)", err, strings.TrimSpace(string(b)))
	}
	for _, m := range keyLineRe.FindAllStringSubmatch(string(b), -1) {
		switch strings.ToLower(m[1]) {
		case "privatekey":
			priv = m[2]
		case "publickey":
			pub = m[2]
		}
	}
	if priv == "" || pub == "" {
		return "", "", fmt.Errorf("не разобрал reality-keypair: %s", strings.TrimSpace(string(b)))
	}
	return priv, pub, nil
}

func generateUUID() (string, error) {
	cmd := exec.Command("sing-box", "generate", "uuid")
	b, err := cmd.CombinedOutput()
	if err == nil {
		u := strings.TrimSpace(string(b))
		if u != "" {
			return u, nil
		}
	}
	// fallback
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	buf[6] = (buf[6] & 0x0f) | 0x40
	buf[8] = (buf[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", buf[0:4], buf[4:6], buf[6:8], buf[8:10], buf[10:16]), nil
}

func generateShortID() (string, error) {
	cmd := exec.Command("sing-box", "generate", "rand", "8", "--hex")
	b, err := cmd.CombinedOutput()
	if err == nil {
		s := strings.TrimSpace(string(b))
		if s != "" {
			return s, nil
		}
	}
	var buf [8]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}
