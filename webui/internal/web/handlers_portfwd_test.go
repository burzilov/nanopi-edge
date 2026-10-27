package web

import (
	"encoding/json"
	"html/template"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"nanopi-webui/internal/portfwd"
)

const boardPortForwards = `{"rules": [
 {"id": "5f1c2a90", "enabled": true, "proto": "tcp", "wan_port": 80, "dest_ip": "10.10.10.179", "dest_port": 80, "comment": "nginx-proxy-manager"},
 {"id": "77ab01cd", "enabled": true, "proto": "tcp", "wan_port": 443, "dest_ip": "10.10.10.179", "dest_port": 443, "comment": "nginx-proxy-manager"},
 {"id": "0d9e3b11", "enabled": true, "proto": "tcp", "wan_port": 5001, "dest_ip": "10.10.10.179", "dest_port": 5001, "comment": "dsm-nas"}
]}`

// portFwdTestServer — сервер с настоящими шаблонами и временными путями.
func portFwdTestServer(t *testing.T) (*Server, string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("PORTFWD_STORE", filepath.Join(dir, "port-forwards.json"))
	t.Setenv("PORTFWD_NFT", filepath.Join(dir, "nanopi-port-forwards.nft"))
	t.Setenv("PORTFWD_NFT_CONF", filepath.Join(dir, "nftables.conf"))
	t.Setenv("PORTFWD_HOME_ROUTE_UNIT", filepath.Join(dir, "home-route.service"))
	t.Setenv("WEBUI_ENV", filepath.Join(dir, ".env"))
	t.Setenv("VLESS_MOBILE_STATE", filepath.Join(dir, "vless.json"))
	t.Setenv("HAIRPIN_DNS_CONF", filepath.Join(dir, "hairpin.conf"))
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.WriteFile(filepath.Join(dir, ".env"), []byte("WAN_IF=end0\nLAN_IF=enp1s0\n"), 0o600))
	must(os.WriteFile(filepath.Join(dir, "nftables.conf"), []byte("flush ruleset\ninclude \"/etc/nftables.d/nanopi-port-forwards.nft\"\n"), 0o644))
	must(os.WriteFile(filepath.Join(dir, "port-forwards.json"), []byte(boardPortForwards), 0o644))
	must(os.WriteFile(filepath.Join(dir, "vless.json"), []byte(`{"enabled": true, "port": 8443}`), 0o600))

	t.Cleanup(portfwd.SetCommandRunner(func(name string, args ...string) ([]byte, error) {
		if name == "ip" && len(args) > 1 && args[1] == "-o" {
			return []byte("3: enp1s0    inet 10.10.10.1/24 scope global enp1s0\n"), nil
		}
		return nil, nil
	}))
	prev := readCounters
	readCounters = func() (map[string]portfwd.Counter, error) {
		return map[string]portfwd.Counter{
			"pf_0d9e3b11_new":   {Packets: 42, Bytes: 2520},
			"pf_0d9e3b11_bytes": {Packets: 900, Bytes: 5 << 20},
			portfwd.DropCounter: {Packets: 7},
		}, nil
	}
	t.Cleanup(func() { readCounters = prev })

	tmpl, err := template.New("").Funcs(template.FuncMap{
		"AppVersion": func() string { return "test" },
	}).ParseGlob(filepath.Join("..", "..", "templates", "*.html"))
	must(err)
	return &Server{Tmpl: tmpl}, dir
}

func post(t *testing.T, h http.Handler, path string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("%s: status %d: %s", path, rr.Code, rr.Body.String())
	}
	return rr
}

func TestPortFwdPage(t *testing.T) {
	srv, _ := portFwdTestServer(t)
	h := srv.Routes()
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/port-forwards", nil))
	if rr.Code != 200 {
		t.Fatalf("status %d: %s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	for _, want := range []string{
		"Проброс портов", `href="/port-forwards"`, "dsm-nas", "10.10.10.179", "NPM",
		"42 / 5.0 МБ", "отброшено подключений: <b>7</b>", "Ограничение частоты",
		`value="120"`, `value="240"`, "Маршрут в домашнюю сеть",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("page missing %q", want)
		}
	}
	// NPM-правила без кнопок удаления/редактирования.
	if strings.Contains(body, `hx-get="/port-forwards/inner?edit=5f1c2a90"`) {
		t.Fatal("NPM rule must be read-only")
	}
	if !strings.Contains(body, `hx-get="/port-forwards/inner?edit=0d9e3b11"`) {
		t.Fatal("user rule must be editable")
	}
}

func TestPortFwdAddEditToggleDelete(t *testing.T) {
	srv, dir := portFwdTestServer(t)
	h := srv.Routes()

	rr := post(t, h, "/port-forwards/add", url.Values{
		"proto": {"udp"}, "wan_port": {"51820"}, "dest_ip": {"10.10.10.20"}, "comment": {"wireguard"},
	})
	if !strings.Contains(rr.Body.String(), "Правило добавлено") {
		t.Fatalf("add: %s", rr.Body.String())
	}
	st, _ := portfwd.Load()
	if len(st.Rules) != 4 || st.Rules[3].DestPort != 51820 || st.Rules[0].Comment != "nginx-proxy-manager" {
		t.Fatalf("store: %+v", st.Rules)
	}
	id := st.Rules[3].ID

	// Ошибки — по-русски, форма сохраняет ввод.
	rr = post(t, h, "/port-forwards/add", url.Values{
		"proto": {"tcp"}, "wan_port": {"5001"}, "dest_ip": {"10.10.10.30"}, "comment": {"dup"},
	})
	if !strings.Contains(rr.Body.String(), "уже занят") || !strings.Contains(rr.Body.String(), `value="10.10.10.30"`) {
		t.Fatalf("conflict: %s", rr.Body.String())
	}
	rr = post(t, h, "/port-forwards/add", url.Values{"proto": {"tcp"}, "wan_port": {"abc"}, "dest_ip": {"10.10.10.30"}})
	if !strings.Contains(rr.Body.String(), "внешний порт") {
		t.Fatal("expected port error")
	}
	rr = post(t, h, "/port-forwards/add", url.Values{"proto": {"tcp"}, "wan_port": {"8443"}, "dest_ip": {"10.10.10.30"}})
	if !strings.Contains(rr.Body.String(), "мобильный VLESS") {
		t.Fatalf("expected VLESS port conflict: %s", rr.Body.String())
	}

	// Редактирование.
	rr = httptest.NewRecorder()
	h.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/port-forwards/inner?edit="+id, nil))
	if !strings.Contains(rr.Body.String(), `hx-post="/port-forwards/update"`) {
		t.Fatalf("edit form: %s", rr.Body.String())
	}
	post(t, h, "/port-forwards/update", url.Values{
		"id": {id}, "proto": {"both"}, "wan_port": {"51821"}, "dest_ip": {"10.10.10.21"}, "dest_port": {"51820"},
	})
	st, _ = portfwd.Load()
	if r := st.Rules[3]; r.Proto != "both" || r.WanPort != 51821 || r.DestIP != "10.10.10.21" {
		t.Fatalf("update: %+v", r)
	}

	rr = post(t, h, "/port-forwards/toggle", url.Values{"id": {id}, "enabled": {"0"}})
	if !strings.Contains(rr.Body.String(), "выключено") {
		t.Fatal(rr.Body.String())
	}
	rr = post(t, h, "/port-forwards/toggle", url.Values{"id": {"5f1c2a90"}, "enabled": {"0"}})
	if !strings.Contains(rr.Body.String(), "Nginx Proxy Manager") {
		t.Fatal("NPM rule toggle must be refused")
	}
	post(t, h, "/port-forwards/delete", url.Values{"id": {id}})
	st, _ = portfwd.Load()
	if len(st.Rules) != 3 || !st.Rules[0].Enabled {
		t.Fatalf("delete: %+v", st.Rules)
	}

	// Ограничение частоты.
	rr = post(t, h, "/port-forwards/rate-limit", url.Values{"enabled": {"1"}, "per_minute": {"60"}, "burst": {"100"}})
	if !strings.Contains(rr.Body.String(), "60 новых подключений") {
		t.Fatal(rr.Body.String())
	}
	b, _ := os.ReadFile(filepath.Join(dir, "nanopi-port-forwards.nft"))
	if !strings.Contains(string(b), "limit rate over 60/minute burst 100 packets") || strings.Contains(string(b), "log prefix") {
		t.Fatalf("nft: %s", b)
	}
	rr = post(t, h, "/port-forwards/rate-limit", url.Values{"per_minute": {"1"}, "burst": {"100"}})
	if !strings.Contains(rr.Body.String(), "порог") {
		t.Fatal(rr.Body.String())
	}

	// Маршрут в домашнюю сеть.
	rr = post(t, h, "/port-forwards/home-route", url.Values{"home_net": {"192.168.1.0/24"}, "home_via": {"10.10.10.179"}})
	if !strings.Contains(rr.Body.String(), "Маршрут сохранён") {
		t.Fatal(rr.Body.String())
	}
}

func TestAPIPortForwards(t *testing.T) {
	srv, _ := portFwdTestServer(t)
	rr := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/api/port-forwards", nil))
	if rr.Code != 200 {
		t.Fatalf("status %d", rr.Code)
	}
	var got struct {
		Rules    []portfwd.Rule             `json:"rules"`
		Limit    portfwd.RateLimit          `json:"effective_rate_limit"`
		Counters map[string]portfwd.Counter `json:"counters"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Rules) != 3 || !got.Limit.Enabled || got.Counters[portfwd.DropCounter].Packets != 7 {
		t.Fatalf("%+v", got)
	}
}

func TestHumanBytes(t *testing.T) {
	for in, want := range map[uint64]string{0: "0 Б", 1023: "1023 Б", 1536: "1.5 КБ", 5 << 20: "5.0 МБ", 300 << 30: "300 ГБ"} {
		if got := humanBytes(in); got != want {
			t.Errorf("%d: %q want %q", in, got, want)
		}
	}
}
