package portfwd

import (
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
		{ID: "1", Proto: "tcp", WanPort: 80, DestIP: "10.10.10.1", DestPort: 80},
		{ID: "2", Proto: "tcp", WanPort: 80, DestIP: "10.10.10.2", DestPort: 8080},
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
		{ID: "1", Enabled: true, Proto: "tcp", WanPort: 443, DestIP: "10.10.10.50", DestPort: 443, Comment: "npm"},
		{ID: "2", Enabled: false, Proto: "udp", WanPort: 53, DestIP: "10.10.10.53", DestPort: 53},
		{ID: "3", Enabled: true, Proto: "both", WanPort: 51820, DestIP: "10.10.10.2", DestPort: 51820},
	}}
	out := RenderNft(s, []string{"end0", "ppp0"})
	if !strings.Contains(out, `iifname { "end0", "ppp0" } tcp dport 443 dnat ip to 10.10.10.50:443 # npm`) {
		t.Fatalf("missing tcp 443 rule:\n%s", out)
	}
	if strings.Contains(out, "dport 53") {
		t.Fatal("disabled rule should not render")
	}
	if !strings.Contains(out, "tcp dport 51820") || !strings.Contains(out, "udp dport 51820") {
		t.Fatalf("both should emit tcp+udp:\n%s", out)
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
	// second call no-op
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
