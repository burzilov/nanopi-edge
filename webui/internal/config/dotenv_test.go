package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSetGetDeleteKV(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte("FOO=1\nBAR=2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := SetKV(path, "HAIRPIN_DNS_TARGET", "192.168.1.137"); err != nil {
		t.Fatal(err)
	}
	v, ok, err := GetKV(path, "HAIRPIN_DNS_TARGET")
	if err != nil || !ok || v != "192.168.1.137" {
		t.Fatalf("get: %v %v %q", err, ok, v)
	}
	if err := SetKV(path, "HAIRPIN_DNS_TARGET", "10.0.0.1"); err != nil {
		t.Fatal(err)
	}
	v, _, _ = GetKV(path, "HAIRPIN_DNS_TARGET")
	if v != "10.0.0.1" {
		t.Fatalf("update: %q", v)
	}
	b, _ := os.ReadFile(path)
	if !containsOnce(string(b), "HAIRPIN_DNS_TARGET=") {
		t.Fatalf("duplicated key: %s", b)
	}
	if err := DeleteKV(path, "HAIRPIN_DNS_TARGET"); err != nil {
		t.Fatal(err)
	}
	_, ok, _ = GetKV(path, "HAIRPIN_DNS_TARGET")
	if ok {
		t.Fatal("expected deleted")
	}
}

func containsOnce(s, sub string) bool {
	n := 0
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			n++
		}
	}
	return n == 1
}
