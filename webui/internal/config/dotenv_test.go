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
	if err := SetKV(path, "EDGE_VERSION", "v0.0.18"); err != nil {
		t.Fatal(err)
	}
	v, ok, err := GetKV(path, "EDGE_VERSION")
	if err != nil || !ok || v != "v0.0.18" {
		t.Fatalf("get: %v %v %q", err, ok, v)
	}
	if err := SetKV(path, "EDGE_VERSION", "v0.0.19"); err != nil {
		t.Fatal(err)
	}
	v, _, _ = GetKV(path, "EDGE_VERSION")
	if v != "v0.0.19" {
		t.Fatalf("update: %q", v)
	}
	b, _ := os.ReadFile(path)
	if !containsOnce(string(b), "EDGE_VERSION=") {
		t.Fatalf("duplicated key: %s", b)
	}
	if err := DeleteKV(path, "EDGE_VERSION"); err != nil {
		t.Fatal(err)
	}
	_, ok, _ = GetKV(path, "EDGE_VERSION")
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
