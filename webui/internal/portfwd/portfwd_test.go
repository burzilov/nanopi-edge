package portfwd

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateRule(t *testing.T) {
	r := Rule{ID: "a1", Proto: "tcp", WanPort: 80, DestIP: "10.10.10.50", DestPort: 80}
	if err := ValidateRule(r); err != nil {
		t.Fatal(err)
	}
	r.DestIP = "not-an-ip"
	if err := ValidateRule(r); err == nil {
		t.Fatal("expected dest_ip error")
	}
	r.DestIP = "10.10.10.50"
	r.WanPort = 0
	if err := ValidateRule(r); err == nil {
		t.Fatal("expected wan_port error")
	}
}

func TestValidateStoreDup(t *testing.T) {
	s := Store{Rules: []Rule{
		{ID: "1", Enabled: true, Proto: "tcp", WanPort: 80, DestIP: "10.10.10.1", DestPort: 80},
		{ID: "2", Enabled: true, Proto: "tcp", WanPort: 80, DestIP: "10.10.10.2", DestPort: 8080},
	}}
	if err := ValidateStore(s); err == nil {
		t.Fatal("expected duplicate error")
	}
	s.Rules[1].Proto = "both"
	if err := ValidateStore(s); err == nil {
		t.Fatal("expected both/tcp conflict")
	}
}

func TestRenderNft(t *testing.T) {
	s := Store{Rules: []Rule{
		{ID: "1", Enabled: true, Proto: "tcp", WanPort: 443, DestIP: "10.10.10.50", DestPort: 443, Comment: "nginx-proxy-manager"},
		{ID: "2", Enabled: false, Proto: "udp", WanPort: 53, DestIP: "10.10.10.53", DestPort: 53},
		{ID: "3", Enabled: true, Proto: "both", WanPort: 51820, DestIP: "10.10.10.2", DestPort: 51820},
	}}
	out := RenderNft(s, []string{"end0", "ppp0"})
	if !strings.Contains(out, `iifname { "end0", "ppp0" } tcp dport 443 counter name "pf_1_new" dnat ip to 10.10.10.50:443 # nginx-proxy-manager`) {
		t.Fatalf("missing tcp 443 rule:\n%s", out)
	}
	if strings.Contains(out, "dport 53") || strings.Contains(out, "pf_2_") {
		t.Fatal("disabled rule should not render")
	}
	if !strings.Contains(out, "tcp dport 51820") || !strings.Contains(out, "udp dport 51820") {
		t.Fatalf("both should emit tcp+udp:\n%s", out)
	}
	if strings.Contains(out, "masquerade") || strings.Contains(out, "postrouting") {
		t.Fatal("port forwards must not render masquerade/postrouting")
	}
}

func TestEnsureNftInclude(t *testing.T) {
	dir := t.TempDir()
	conf := filepath.Join(dir, "nftables.conf")
	if err := os.WriteFile(conf, []byte("flush ruleset\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := EnsureNftInclude(conf); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(conf)
	if !strings.Contains(string(b), "nanopi-port-forwards.nft") {
		t.Fatalf("include not added: %s", b)
	}
	if err := EnsureNftInclude(conf); err != nil {
		t.Fatal(err)
	}
	b2, _ := os.ReadFile(conf)
	if strings.Count(string(b2), "nanopi-port-forwards.nft") != 1 {
		t.Fatal("include duplicated")
	}
}

func TestSaveLoad(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PORTFWD_STORE", filepath.Join(dir, "port-forwards.json"))
	s := Store{Rules: []Rule{
		NormalizeRule(Rule{Proto: "tcp", WanPort: 80, DestIP: "10.10.10.5", DestPort: 80, Comment: "x"}),
	}}
	s.Rules[0].Enabled = true
	if err := Save(s); err != nil {
		t.Fatal(err)
	}
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Rules) != 1 || got.Rules[0].WanPort != 80 {
		t.Fatalf("unexpected load: %+v", got)
	}
}

// --- окружение для Mutate: временные пути и подменённые команды ---

type fakeExec struct {
	calls   []string
	failOn  string // подстрока команды, которая вернёт ошибку
	ipAddr  string // вывод `ip -4 -o addr show`
	nftJSON string
}

func (f *fakeExec) run(name string, args ...string) ([]byte, error) {
	cmd := name + " " + strings.Join(args, " ")
	f.calls = append(f.calls, cmd)
	if f.failOn != "" && strings.Contains(cmd, f.failOn) {
		return []byte("Error: syntax error"), errors.New("exit status 1")
	}
	if name == "ip" && len(args) > 2 && args[1] == "-o" {
		return []byte(f.ipAddr), nil
	}
	if name == "nft" && len(args) > 0 && args[0] == "-j" {
		return []byte(f.nftJSON), nil
	}
	return nil, nil
}

func (f *fakeExec) has(sub string) bool {
	for _, c := range f.calls {
		if strings.Contains(c, sub) {
			return true
		}
	}
	return false
}

func setupEnv(t *testing.T, storeJSON string) (*fakeExec, string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("PORTFWD_STORE", filepath.Join(dir, "port-forwards.json"))
	t.Setenv("PORTFWD_NFT", filepath.Join(dir, "nftables.d", "nanopi-port-forwards.nft"))
	t.Setenv("PORTFWD_NFT_CONF", filepath.Join(dir, "nftables.conf"))
	t.Setenv("WEBUI_ENV", filepath.Join(dir, ".env"))
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("WAN_IF=end0\nLAN_IF=enp1s0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "nftables.conf"), []byte("flush ruleset\ninclude \"/etc/nftables.d/nanopi-port-forwards.nft\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if storeJSON != "" {
		if err := os.WriteFile(filepath.Join(dir, "port-forwards.json"), []byte(storeJSON), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	f := &fakeExec{ipAddr: "3: enp1s0    inet 10.10.10.1/24 brd 10.10.10.255 scope global enp1s0\n"}
	t.Cleanup(SetCommandRunner(f.run))
	return f, dir
}

// Формат port-forwards.json, который уже лежит на плате.
const boardJSON = `{
  "rules": [
    {"id": "5f1c2a90", "enabled": true, "proto": "tcp", "wan_port": 80, "dest_ip": "10.10.10.179", "dest_port": 80, "comment": "nginx-proxy-manager"},
    {"id": "77ab01cd", "enabled": true, "proto": "tcp", "wan_port": 443, "dest_ip": "10.10.10.179", "dest_port": 443, "comment": "nginx-proxy-manager"},
    {"id": "0d9e3b11", "enabled": true, "proto": "tcp", "wan_port": 5001, "dest_ip": "10.10.10.179", "dest_port": 5001, "comment": "dsm-nas"}
  ]
}
`

func TestBoardStoreCompat(t *testing.T) {
	_, dir := setupEnv(t, boardJSON)
	s, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateStore(s); err != nil {
		t.Fatal(err)
	}
	if len(s.Rules) != 3 || s.Rules[0].Comment != "nginx-proxy-manager" || s.Rules[2].Comment != "dsm-nas" {
		t.Fatalf("unexpected rules: %+v", s.Rules)
	}
	if s.RateLimit != nil || !s.Limit().Enabled || s.Limit().PerMinute != DefaultRatePerMinute {
		t.Fatalf("old file must get default rate limit: %+v", s.Limit())
	}
	out := RenderNft(s, WanInterfaces())
	for _, want := range []string{
		`tcp dport 80 counter name "pf_5f1c2a90_new" dnat ip to 10.10.10.179:80`,
		`tcp dport 443 counter name "pf_77ab01cd_new" dnat ip to 10.10.10.179:443`,
		`tcp dport 5001 counter name "pf_0d9e3b11_new" dnat ip to 10.10.10.179:5001 # dsm-nas`,
		`tcp dport { 80, 443, 5001 } update @ratelimit_src`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q:\n%s", want, out)
		}
	}
	// Перезапись без изменений не теряет поля и не добавляет rate_limit.
	if _, err := Reapply(); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "port-forwards.json"))
	if strings.Contains(string(b), "rate_limit") || strings.Count(string(b), `"id"`) != 3 {
		t.Fatalf("store changed: %s", b)
	}
}

func TestRenderNftAtomicPrefix(t *testing.T) {
	out := RenderNft(Store{}, nil)
	i1 := strings.Index(out, "add table inet nanopi_portforward\n")
	i2 := strings.Index(out, "delete table inet nanopi_portforward\n")
	i3 := strings.Index(out, "table inet nanopi_portforward {")
	if i1 < 0 || i2 < i1 || i3 < i2 {
		t.Fatalf("file must be idempotent (add/delete/define):\n%s", out)
	}
	if strings.Contains(out, "flush ruleset") {
		t.Fatal("must not flush ruleset")
	}
	if strings.Contains(out, "ratelimit") || strings.Contains(out, "chain forward") {
		t.Fatalf("no rules → no ratelimit/forward chains:\n%s", out)
	}
}

func TestRenderNftRateLimit(t *testing.T) {
	s := Store{Rules: []Rule{
		{ID: "a", Enabled: true, Proto: "both", WanPort: 5001, DestIP: "10.10.10.179", DestPort: 5001},
		{ID: "b", Enabled: true, Proto: "tcp", WanPort: 443, DestIP: "10.10.10.179", DestPort: 443},
		{ID: "c", Enabled: false, Proto: "tcp", WanPort: 22, DestIP: "10.10.10.5", DestPort: 22},
	}}
	out := RenderNft(s, []string{"end0", "ppp0"})
	for _, want := range []string{
		`counter pf_ratelimit_drop {`,
		`flags dynamic,timeout`,
		`type filter hook prerouting priority -150; policy accept;`,
		`iifname { "end0", "ppp0" } meta nfproto ipv4 ct state new tcp dport { 5001, 443 } update @ratelimit_src { ip saddr limit rate over 120/minute burst 240 packets } counter name "pf_ratelimit_drop" jump ratelimit_drop`,
		`ct state new udp dport { 5001 }`,
		`log prefix "nanopi-pf-ratelimit: " level warn`,
		`ct status dnat ct original protocol udp ct original proto-dst 5001 ct reply ip saddr 10.10.10.179 ct reply proto-src 5001 counter name "pf_a_bytes"`,
		`counter pf_b_new {`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "dport { 5001, 443, 22 }") || strings.Contains(out, "pf_c_") {
		t.Fatal("disabled rule must not be limited/counted")
	}
	// Лимит только на вход с WAN — у каждой строки ratelimit есть iifname.
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "update @ratelimit_src") && !strings.Contains(line, "iifname {") {
			t.Fatalf("ratelimit must be WAN-only: %s", line)
		}
	}
	s.RateLimit = &RateLimit{Enabled: true, PerMinute: 60, Burst: 100, Log: false}
	out = RenderNft(s, []string{"end0"})
	if !strings.Contains(out, "limit rate over 60/minute burst 100 packets") || strings.Contains(out, "log prefix") {
		t.Fatalf("custom limit not rendered:\n%s", out)
	}
	s.RateLimit.Enabled = false
	out = RenderNft(s, []string{"end0"})
	if strings.Contains(out, "ratelimit") {
		t.Fatalf("disabled limit must not render:\n%s", out)
	}
	if !strings.Contains(out, `counter name "pf_a_new"`) {
		t.Fatal("counters must stay without rate limit")
	}
}

func TestValidateRateLimit(t *testing.T) {
	if err := ValidateRateLimit(DefaultRateLimit()); err != nil {
		t.Fatal(err)
	}
	for _, rl := range []RateLimit{{PerMinute: 5, Burst: 10}, {PerMinute: 60, Burst: 0}, {PerMinute: 1 << 20, Burst: 1}} {
		if err := ValidateRateLimit(rl); err == nil {
			t.Fatalf("expected error for %+v", rl)
		}
	}
}

func TestValidateStoreDisabledNoConflict(t *testing.T) {
	s := Store{Rules: []Rule{
		{ID: "1", Enabled: true, Proto: "tcp", WanPort: 80, DestIP: "10.10.10.1", DestPort: 80},
		{ID: "2", Enabled: false, Proto: "tcp", WanPort: 80, DestIP: "10.10.10.2", DestPort: 80},
		{ID: "3", Enabled: true, Proto: "udp", WanPort: 80, DestIP: "10.10.10.3", DestPort: 80},
	}}
	if err := ValidateStore(s); err != nil {
		t.Fatalf("disabled duplicate and tcp/udp on same port are fine: %v", err)
	}
	s.Rules[1].Enabled = true
	err := ValidateStore(s)
	if err == nil || !strings.Contains(err.Error(), "уже занят") {
		t.Fatalf("expected conflict, got %v", err)
	}
}

func TestValidateRuleRejects(t *testing.T) {
	base := Rule{ID: "ab12", Proto: "tcp", WanPort: 80, DestIP: "10.10.10.5", DestPort: 80}
	for name, mut := range map[string]func(*Rule){
		"loopback": func(r *Rule) { r.DestIP = "127.0.0.1" },
		"zero":     func(r *Rule) { r.DestIP = "0.0.0.0" },
		"bcast":    func(r *Rule) { r.DestIP = "255.255.255.255" },
		"mcast":    func(r *Rule) { r.DestIP = "224.0.0.1" },
		"ipv6":     func(r *Rule) { r.DestIP = "fd00::1" },
		"proto":    func(r *Rule) { r.Proto = "icmp" },
		"destport": func(r *Rule) { r.DestPort = 70000 },
		"comment":  func(r *Rule) { r.Comment = strings.Repeat("я", MaxCommentLen+1) },
		"newline":  func(r *Rule) { r.Comment = "a\nb" },
		"badid":    func(r *Rule) { r.ID = "a b" },
	} {
		r := base
		mut(&r)
		if err := ValidateRule(r); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
	r := base
	r.Comment = strings.Repeat("я", MaxCommentLen)
	if err := ValidateRule(r); err != nil {
		t.Fatalf("120 cyrillic runes must be ok: %v", err)
	}
}

func TestMutateAddUpdateToggleDelete(t *testing.T) {
	f, dir := setupEnv(t, boardJSON)
	st, err := Add(Rule{Proto: "both", WanPort: 51820, DestIP: " 10.10.10.20 ", DestPort: 51820, Comment: "wg"})
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Rules) != 4 || !st.Rules[3].Enabled || st.Rules[3].DestIP != "10.10.10.20" {
		t.Fatalf("add: %+v", st.Rules)
	}
	id := st.Rules[3].ID
	nftFile := filepath.Join(dir, "nftables.d", "nanopi-port-forwards.nft")
	b, _ := os.ReadFile(nftFile)
	if !strings.Contains(string(b), "udp dport 51820") || !strings.Contains(string(b), "dsm-nas") {
		t.Fatalf("nft file not written: %s", b)
	}
	if !f.has("nft -c -f") || !f.has("nft -f "+nftFile) {
		t.Fatalf("expected check + table-only apply, got %v", f.calls)
	}
	for _, c := range f.calls {
		if strings.Contains(c, "systemctl") || strings.Contains(c, "nftables.conf") {
			t.Fatalf("must not restart sing-box / reload nftables.conf: %s", c)
		}
	}

	st, err = Update(Rule{ID: id, Proto: "udp", WanPort: 51821, DestIP: "10.10.10.21", DestPort: 51820})
	if err != nil {
		t.Fatal(err)
	}
	if r := st.Rules[3]; r.ID != id || r.Proto != "udp" || r.WanPort != 51821 || !r.Enabled {
		t.Fatalf("update: %+v", r)
	}
	if _, err := SetEnabled(id, false); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(nftFile)
	if strings.Contains(string(b), "51821") {
		t.Fatal("disabled rule still rendered")
	}
	st, err = Delete(id)
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Rules) != 3 {
		t.Fatalf("delete: %+v", st.Rules)
	}
	if _, err := Delete("nope"); err == nil {
		t.Fatal("expected not found")
	}
	// Конфликт с существующим dsm-nas.
	if _, err := Add(Rule{Proto: "tcp", WanPort: 5001, DestIP: "10.10.10.30", DestPort: 5001}); err == nil || !strings.Contains(err.Error(), "dsm-nas") {
		t.Fatalf("expected conflict naming dsm-nas, got %v", err)
	}
}

// Правила бывшей страницы NPM (комментарий nginx-proxy-manager) — обычные
// правила: их можно менять, выключать и удалять, комментарий не зарезервирован.
func TestFormerNPMRulesEditable(t *testing.T) {
	setupEnv(t, boardJSON)
	if _, err := Update(Rule{ID: "5f1c2a90", Proto: "tcp", WanPort: 8080, DestIP: "10.10.10.179", DestPort: 80, Comment: "nginx-proxy-manager"}); err != nil {
		t.Fatal(err)
	}
	if _, err := SetEnabled("77ab01cd", false); err != nil {
		t.Fatal(err)
	}
	if _, err := Add(Rule{Proto: "tcp", WanPort: 8444, DestIP: "10.10.10.179", DestPort: 8444, Comment: "nginx-proxy-manager"}); err != nil {
		t.Fatal(err)
	}
	st, err := Delete("5f1c2a90")
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Rules) != 3 || st.Rules[0].ID != "77ab01cd" || st.Rules[0].Enabled {
		t.Fatalf("%+v", st.Rules)
	}
}

// Старый port-forwards.json с полями маршрута в домашнюю сеть читается,
// поля игнорируются: в nft нет masquerade, при сохранении поля пропадают.
func TestLegacyHomeRouteFieldsIgnored(t *testing.T) {
	legacy := `{"home_net": "192.168.1.0/24", "home_via": "10.10.10.179", "rules": [
    {"id": "0d9e3b11", "enabled": true, "proto": "tcp", "wan_port": 5001, "dest_ip": "10.10.10.179", "dest_port": 5001, "comment": "dsm-nas"}
  ]}`
	_, dir := setupEnv(t, legacy)
	s, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	out := RenderNft(s, WanInterfaces())
	if strings.Contains(out, "masquerade") || !strings.Contains(out, "dnat ip to 10.10.10.179:5001") {
		t.Fatalf("%s", out)
	}
	if _, err := Reapply(); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "port-forwards.json"))
	if strings.Contains(string(b), "home_") || !strings.Contains(string(b), "dsm-nas") {
		t.Fatalf("%s", b)
	}
}

func TestCommitRollbackOnApplyError(t *testing.T) {
	f, dir := setupEnv(t, boardJSON)
	before, _ := os.ReadFile(filepath.Join(dir, "port-forwards.json"))
	f.failOn = "nft -c"
	if _, err := Add(Rule{Proto: "tcp", WanPort: 22, DestIP: "10.10.10.5", DestPort: 22}); err == nil || !strings.Contains(err.Error(), "nft отклонил") {
		t.Fatalf("expected nft check error, got %v", err)
	}
	after, _ := os.ReadFile(filepath.Join(dir, "port-forwards.json"))
	if string(before) != string(after) {
		t.Fatal("store changed after failed check")
	}
	// Ошибка уже при загрузке — JSON и nft-файл откатываются.
	f.failOn = ""
	if _, err := Reapply(); err != nil {
		t.Fatal(err)
	}
	nftFile := filepath.Join(dir, "nftables.d", "nanopi-port-forwards.nft")
	nftBefore, _ := os.ReadFile(nftFile)
	before, _ = os.ReadFile(filepath.Join(dir, "port-forwards.json"))
	f.failOn = "nft -f " + nftFile
	if _, err := Add(Rule{Proto: "tcp", WanPort: 22, DestIP: "10.10.10.5", DestPort: 22}); err == nil {
		t.Fatal("expected apply error")
	}
	after, _ = os.ReadFile(filepath.Join(dir, "port-forwards.json"))
	nftAfter, _ := os.ReadFile(nftFile)
	if string(before) != string(after) || string(nftBefore) != string(nftAfter) {
		t.Fatal("rollback failed")
	}
}

func TestDestHint(t *testing.T) {
	if h, w := DestHint("10.10.10.0/24", "10.10.10.179"); w || h != "" {
		t.Fatalf("LAN address needs no hint: %q", h)
	}
	if h, w := DestHint("10.10.10.0/24", "192.168.1.5"); !w || !strings.Contains(h, "роутер") {
		t.Fatalf("expected warning: %q", h)
	}
}

func TestSetRateLimitAndCounters(t *testing.T) {
	f, dir := setupEnv(t, boardJSON)
	if _, err := SetRateLimit(RateLimit{Enabled: true, PerMinute: 3, Burst: 10}); err == nil {
		t.Fatal("too low limit must fail")
	}
	st, err := SetRateLimit(RateLimit{Enabled: true, PerMinute: 60, Burst: 100, Log: true})
	if err != nil {
		t.Fatal(err)
	}
	if st.Limit().PerMinute != 60 || len(st.Rules) != 3 {
		t.Fatalf("%+v", st)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "nftables.d", "nanopi-port-forwards.nft"))
	if !strings.Contains(string(b), "limit rate over 60/minute burst 100 packets") {
		t.Fatalf("nft: %s", b)
	}
	f.nftJSON = `{"nftables": [{"metainfo": {"version": "1.0.6"}}, {"table": {"family": "inet", "name": "nanopi_portforward"}},
	 {"counter": {"family": "inet", "name": "pf_0d9e3b11_new", "table": "nanopi_portforward", "handle": 3, "packets": 42, "bytes": 2520}},
	 {"counter": {"family": "inet", "name": "pf_0d9e3b11_bytes", "table": "nanopi_portforward", "handle": 4, "packets": 9000, "bytes": 12345678}},
	 {"counter": {"family": "inet", "name": "pf_ratelimit_drop", "table": "nanopi_portforward", "handle": 5, "packets": 7, "bytes": 420}},
	 {"chain": {"family": "inet", "table": "nanopi_portforward", "name": "prerouting"}}]}`
	c, err := Counters()
	if err != nil {
		t.Fatal(err)
	}
	cn, cb := CounterNames("0d9e3b11")
	if c[cn].Packets != 42 || c[cb].Bytes != 12345678 || c[DropCounter].Packets != 7 {
		t.Fatalf("%+v", c)
	}
}

func TestReconcile(t *testing.T) {
	f, dir := setupEnv(t, "")
	if ch, err := Reconcile(); err != nil || ch || len(f.calls) != 0 {
		t.Fatalf("no store → no-op: %v %v %v", ch, err, f.calls)
	}
	if err := os.WriteFile(filepath.Join(dir, "port-forwards.json"), []byte(boardJSON), 0o644); err != nil {
		t.Fatal(err)
	}
	// Старый формат файла на плате (без add/delete и счётчиков).
	nftFile := filepath.Join(dir, "nftables.d", "nanopi-port-forwards.nft")
	_ = os.MkdirAll(filepath.Dir(nftFile), 0o755)
	_ = os.WriteFile(nftFile, []byte("table inet nanopi_portforward {\n}\n"), 0o644)
	ch, err := Reconcile()
	if err != nil || !ch {
		t.Fatalf("expected update: %v %v", ch, err)
	}
	b, _ := os.ReadFile(nftFile)
	if !strings.Contains(string(b), "add table inet nanopi_portforward") || !strings.Contains(string(b), "dsm-nas") {
		t.Fatalf("%s", b)
	}
	f.calls = nil
	if ch, err := Reconcile(); err != nil || ch || f.has("nft -f") {
		t.Fatalf("second run must be no-op: %v %v %v", ch, err, f.calls)
	}
}
