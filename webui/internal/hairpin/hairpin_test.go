package hairpin

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNormalizeTarget(t *testing.T) {
	for in, want := range map[string]string{
		"": "", "  ": "", "192.168.1.137": "192.168.1.137", " 10.0.0.5 ": "10.0.0.5",
	} {
		got, err := NormalizeTarget(in)
		if err != nil || got != want {
			t.Errorf("%q: got %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"abc", "192.168.1", "192.168.1.300", "::1", "fe80::1", "0.0.0.0", "127.0.0.1", "224.0.0.1", "255.255.255.255", "::ffff:192.168.1.1"} {
		if _, err := NormalizeTarget(bad); err == nil {
			t.Errorf("%q must be rejected", bad)
		}
	}
}

// Apply пишет .env и вызывает скрипт обновления (как CLI hairpin-dns-refresh).
func TestApplyWithScript(t *testing.T) {
	dir := t.TempDir()
	env := filepath.Join(dir, ".env")
	ran := filepath.Join(dir, "ran")
	script := filepath.Join(dir, "refresh")
	t.Setenv("WEBUI_ENV", env)
	t.Setenv("HAIRPIN_DNS_SCRIPT", script)
	t.Setenv("HAIRPIN_DNS_CONF", filepath.Join(dir, "hairpin.conf"))
	if err := os.WriteFile(env, []byte("WAN_IF=end0\nHAIRPIN_DNS_TARGET=192.168.1.10\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho run >> "+ran+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Apply(" 192.168.1.137 "); err != nil {
		t.Fatal(err)
	}
	if v, _ := GetTarget(); v != "192.168.1.137" {
		t.Fatalf("target %q", v)
	}
	b, _ := os.ReadFile(env)
	if !strings.Contains(string(b), "WAN_IF=end0") || strings.Count(string(b), "HAIRPIN_DNS_TARGET=") != 1 {
		t.Fatalf(".env: %s", b)
	}
	if err := Apply("bad"); err == nil {
		t.Fatal("bad target must fail")
	}
	if v, _ := GetTarget(); v != "192.168.1.137" {
		t.Fatalf("bad input must not change .env: %q", v)
	}
	if err := Apply(""); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(env)
	if strings.Contains(string(b), "HAIRPIN_DNS_TARGET") {
		t.Fatalf("target must be removed: %s", b)
	}
	r, _ := os.ReadFile(ran)
	if strings.Count(string(r), "run") != 2 {
		t.Fatalf("script runs: %q", r)
	}
}

func TestNormalizeName(t *testing.T) {
	for in, want := range map[string]string{
		"nas.example.com": "nas.example.com", " NAS.Example.ORG. ": "nas.example.org",
		"*.nas.example.com": "nas.example.com", "a-b.c1.xn--p1ai": "a-b.c1.xn--p1ai",
	} {
		got, err := NormalizeName(in)
		if err != nil || got != want {
			t.Errorf("%q: got %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "localhost", "https://nas.example.com", "nas.example.com:5001",
		"nas.example.com/photo", "bad name.me", "-a.me", "a-.me", "a..me", "192.168.1.90", "a.123",
		"пример.рф", "under_score.me", strings.Repeat("a", 64) + ".me"} {
		if _, err := NormalizeName(bad); err == nil {
			t.Errorf("%q must be rejected", bad)
		}
	}
}

func TestRenderConf(t *testing.T) {
	ov := []Override{{Name: "nas.example.com", IP: "192.168.1.90"}}
	if RenderConf("", []string{"203.0.113.10"}, nil) != "" {
		t.Fatal("nothing to write when target and overrides are empty")
	}
	got := RenderConf("192.168.1.137", []string{"203.0.113.10", "203.0.113.10", "192.168.1.137"}, ov)
	if !strings.Contains(got, "address=/nas.example.com/192.168.1.90\n") ||
		strings.Count(got, "alias=") != 1 || !strings.Contains(got, "alias=203.0.113.10,192.168.1.137\n") {
		t.Fatalf("conf:\n%s", got)
	}
	got = RenderConf("", []string{"203.0.113.10"}, ov)
	if !strings.Contains(got, "address=/nas.example.com/192.168.1.90\n") || strings.Contains(got, "alias=") {
		t.Fatalf("overrides without target:\n%s", got)
	}
}

func TestOverridesAddDelete(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "hairpin-overrides.json")
	ran := filepath.Join(dir, "ran")
	script := filepath.Join(dir, "refresh")
	t.Setenv("WEBUI_ENV", filepath.Join(dir, ".env"))
	t.Setenv("HAIRPIN_OVERRIDES", path)
	t.Setenv("HAIRPIN_DNS_SCRIPT", script)
	t.Setenv("HAIRPIN_DNS_CONF", filepath.Join(dir, "hairpin.conf"))
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho run >> "+ran+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if l, err := LoadOverrides(); err != nil || len(l) != 0 {
		t.Fatalf("no file: %v %v", l, err)
	}
	o, err := AddOverride(" Nas.Example.com ", " 192.168.1.90 ")
	if err != nil || o != (Override{"nas.example.com", "192.168.1.90"}) {
		t.Fatalf("%+v %v", o, err)
	}
	if _, err := AddOverride("nas.example.com.", "192.168.1.91"); err == nil || !strings.Contains(err.Error(), "уже есть") {
		t.Fatalf("duplicate: %v", err)
	}
	for _, bad := range [][2]string{{"bad name", "192.168.1.1"}, {"ok.example.org", ""}, {"ok.example.org", "1.2.3"}} {
		if _, err := AddOverride(bad[0], bad[1]); err == nil {
			t.Errorf("%v must fail", bad)
		}
	}
	l, _ := LoadOverrides()
	if len(l) != 1 {
		t.Fatalf("list %+v", l)
	}
	// Статус: строки ещё нет в конфиге (скрипт-заглушка его не пишет).
	st, err := GetStatus()
	if err != nil || len(st.Overrides) != 1 || st.Overrides[0].Applied {
		t.Fatalf("%+v %v", st, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "hairpin.conf"), []byte(RenderConf("", nil, l)), 0o644); err != nil {
		t.Fatal(err)
	}
	if st, _ = GetStatus(); !st.Overrides[0].Applied {
		t.Fatalf("must be applied: %+v", st)
	}
	if err := DeleteOverride("nope.example.org"); err == nil {
		t.Fatal("unknown name must fail")
	}
	if err := DeleteOverride("NAS.example.com"); err != nil {
		t.Fatal(err)
	}
	if l, _ = LoadOverrides(); len(l) != 0 {
		t.Fatalf("after delete %+v", l)
	}
	r, _ := os.ReadFile(ran)
	if n := strings.Count(string(r), "run"); n != 2 {
		t.Fatalf("refresh runs: %d", n)
	}
}

func TestOverridesLimitAndRollback(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "hairpin-overrides.json")
	script := filepath.Join(dir, "refresh")
	t.Setenv("HAIRPIN_OVERRIDES", path)
	t.Setenv("HAIRPIN_DNS_SCRIPT", script)
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < MaxOverrides; i++ {
		if _, err := AddOverride(fmt.Sprintf("h%d.example.org", i), "192.168.1.10"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := AddOverride("extra.example.org", "192.168.1.10"); err == nil {
		t.Fatal("limit must apply")
	}
	// Ошибка применения — файл возвращается к прежнему виду.
	if err := os.WriteFile(script, []byte("#!/bin/sh\necho boom; exit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := DeleteOverride("h0.example.org"); err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("refresh failure must be reported: %v", err)
	}
	if l, _ := LoadOverrides(); len(l) != MaxOverrides {
		t.Fatalf("rollback: %d", len(l))
	}
}
