package sbconfig

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSetSelectorDefault(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	raw := `{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "selector", "tag": "proxy", "outbounds": ["a", "b"], "default": "a"},
    {"type": "vless", "tag": "a"},
    {"type": "vless", "tag": "b"}
  ]
}`
	if err := os.WriteFile(path, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := SetSelectorDefault(path, "proxy", "b"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	if !containsDefault(string(b), "b") {
		t.Fatalf("default not updated: %s", b)
	}
}

func containsDefault(s, want string) bool {
	return len(s) > 0 && (stringIndex(s, `"default": "`+want+`"`) >= 0 || stringIndex(s, `"default":"`+want+`"`) >= 0)
}

func stringIndex(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
