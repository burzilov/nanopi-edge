package hairpin

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Исключения из общей подмены: «имя → адрес».
//
// Общая подмена (HAIRPIN_DNS_TARGET) переписывает любой ответ с белым IP на
// один адрес (обычно Nginx Proxy Manager). Исключения нужны для имён, которые
// дома должны вести на другое устройство (например, DSM на NAS). Для каждого
// исключения dnsmasq получает address=/<имя>/<ip>: ответ даётся локально, до
// форварда, поэтому alias= его не трогает. address=/ покрывает и поддомены.
//
// Хранятся отдельно от .env (переживают перезапись .env установщиком):
// /opt/nanopi-edge/hairpin-overrides.json, {"overrides":[{"name":..,"ip":..}]}.
// Тот же файл читает scripts/common.sh (jq) при hairpin-dns-refresh.

const (
	DefaultOverridesPath = "/opt/nanopi-edge/hairpin-overrides.json"
	MaxOverrides         = 50
)

type Override struct {
	Name string `json:"name"`
	IP   string `json:"ip"`
}

type overridesFile struct {
	Overrides []Override `json:"overrides"`
}

var overridesMu sync.Mutex

func OverridesPath() string {
	if v := os.Getenv("HAIRPIN_OVERRIDES"); v != "" {
		return v
	}
	return DefaultOverridesPath
}

// LoadOverrides читает исключения. Нет файла — пустой список.
func LoadOverrides() ([]Override, error) {
	b, err := os.ReadFile(OverridesPath())
	if err != nil {
		if os.IsNotExist(err) {
			return []Override{}, nil
		}
		return nil, err
	}
	if strings.TrimSpace(string(b)) == "" {
		return []Override{}, nil
	}
	var f overridesFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", OverridesPath(), err)
	}
	if f.Overrides == nil {
		f.Overrides = []Override{}
	}
	return f.Overrides, nil
}

func saveOverrides(list []Override) error {
	path := OverridesPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if list == nil {
		list = []Override{}
	}
	b, err := json.MarshalIndent(overridesFile{Overrides: list}, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// NormalizeName проверяет DNS-имя и приводит его к нижнему регистру без
// завершающей точки. «*.» в начале отбрасывается: поддомены и так входят.
func NormalizeName(s string) (string, error) {
	s = strings.ToLower(strings.TrimSpace(s))
	if s == "" {
		return "", fmt.Errorf("укажите имя, например nas.example.com")
	}
	if strings.Contains(s, "://") || strings.ContainsAny(s, "/:@?#") {
		return "", fmt.Errorf("имя %q: нужно только имя, без https://, порта и пути (например, nas.example.com)", s)
	}
	s = strings.TrimPrefix(s, "*.")
	s = strings.TrimSuffix(s, ".")
	for _, r := range s {
		if r > 0x7f {
			return "", fmt.Errorf("имя %q: нелатинские имена укажите в punycode (xn--...)", s)
		}
	}
	if net.ParseIP(s) != nil {
		return "", fmt.Errorf("%q — это адрес, а нужно имя, например nas.example.com", s)
	}
	if len(s) > 253 {
		return "", fmt.Errorf("имя длиннее 253 символов")
	}
	labels := strings.Split(s, ".")
	if len(labels) < 2 {
		return "", fmt.Errorf("имя %q: нужно полное имя с точкой, например nas.example.com", s)
	}
	for _, l := range labels {
		if l == "" || len(l) > 63 {
			return "", fmt.Errorf("имя %q: пустая или слишком длинная часть между точками", s)
		}
		if l[0] == '-' || l[len(l)-1] == '-' {
			return "", fmt.Errorf("имя %q: часть имени не может начинаться или заканчиваться дефисом", s)
		}
		for i := 0; i < len(l); i++ {
			c := l[i]
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return "", fmt.Errorf("имя %q: допустимы латинские буквы, цифры, точка и дефис", s)
			}
		}
	}
	if tld := labels[len(labels)-1]; strings.Trim(tld, "0123456789") == "" {
		return "", fmt.Errorf("имя %q: последняя часть не может состоять из цифр", s)
	}
	return s, nil
}

// NormalizeOverrideIP — адрес исключения (IPv4 как у общей подмены, но обязателен).
func NormalizeOverrideIP(s string) (string, error) {
	if strings.TrimSpace(s) == "" {
		return "", fmt.Errorf("укажите IPv4-адрес в домашней сети, например 192.168.1.90")
	}
	return NormalizeTarget(s)
}

// AddOverride добавляет исключение, перегенерирует конфиг dnsmasq и
// перезапускает его. При ошибке применения файл возвращается к прежнему виду.
func AddOverride(name, ip string) (Override, error) {
	n, err := NormalizeName(name)
	if err != nil {
		return Override{}, err
	}
	a, err := NormalizeOverrideIP(ip)
	if err != nil {
		return Override{}, err
	}
	o := Override{Name: n, IP: a}
	overridesMu.Lock()
	defer overridesMu.Unlock()
	list, err := LoadOverrides()
	if err != nil {
		return Override{}, err
	}
	for _, x := range list {
		if x.Name == n {
			return Override{}, fmt.Errorf("исключение для %s уже есть (→ %s); удалите его и добавьте заново", n, x.IP)
		}
	}
	if len(list) >= MaxOverrides {
		return Override{}, fmt.Errorf("не больше %d исключений", MaxOverrides)
	}
	next := append(append([]Override{}, list...), o)
	if err := commitOverrides(list, next); err != nil {
		return Override{}, err
	}
	return o, nil
}

// DeleteOverride удаляет исключение по имени и применяет конфиг.
func DeleteOverride(name string) error {
	n := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(name)), ".")
	overridesMu.Lock()
	defer overridesMu.Unlock()
	list, err := LoadOverrides()
	if err != nil {
		return err
	}
	next := make([]Override, 0, len(list))
	for _, x := range list {
		if x.Name != n {
			next = append(next, x)
		}
	}
	if len(next) == len(list) {
		return fmt.Errorf("исключение %s не найдено — обновите страницу", n)
	}
	return commitOverrides(list, next)
}

func commitOverrides(prev, next []Override) error {
	if err := saveOverrides(next); err != nil {
		return err
	}
	if err := Refresh(); err != nil {
		if rerr := saveOverrides(prev); rerr == nil {
			_ = Refresh()
		}
		return err
	}
	return nil
}

// RenderConf — содержимое hairpin-alias.conf (то же пишет scripts/common.sh).
// Пусто — файл не нужен (нет ни общей подмены, ни исключений).
func RenderConf(target string, wan []string, overrides []Override) string {
	if target == "" && len(overrides) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("# Managed by nanopi-webui — hairpin DNS (do not edit)\n")
	if target != "" {
		b.WriteString("# HAIRPIN_DNS_TARGET=" + target + "\n")
	}
	if len(overrides) > 0 {
		b.WriteString("# Исключения (" + OverridesPath() + "): имя и поддомены → свой адрес, до alias\n")
		for _, o := range overrides {
			b.WriteString("address=/" + o.Name + "/" + o.IP + "\n")
		}
	}
	if target != "" {
		if len(wan) == 0 {
			b.WriteString("# WAN IPv4 пока нет\n")
		}
		seen := map[string]bool{}
		for _, ip := range wan {
			if ip == target || seen[ip] {
				continue
			}
			seen[ip] = true
			b.WriteString("alias=" + ip + "," + target + "\n")
		}
	}
	return b.String()
}
