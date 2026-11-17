package wan

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizeMAC(t *testing.T) {
	for _, tc := range []struct {
		input, want string
		valid       bool
	}{
		{"", "", true}, {" 02:AA:bb:cc:dd:ee ", "02:aa:bb:cc:dd:ee", true},
		{"01:00:5e:00:00:01", "", false}, {"ff:ff:ff:ff:ff:ff", "", false},
		{"00:00:00:00:00:00", "", false}, {"02-11-22-33-44-55", "", false},
		{"02:11:22:33:44", "", false},
	} {
		got, err := NormalizeMAC(tc.input)
		if (err == nil) != tc.valid || got != tc.want {
			t.Errorf("NormalizeMAC(%q) = %q, %v", tc.input, got, err)
		}
	}
}

func TestMACStatus(t *testing.T) {
	dir := t.TempDir()
	env := filepath.Join(dir, "env")
	if err := os.WriteFile(env, []byte("WAN_MAC=02:11:22:33:44:55\nWAN_PERMANENT_MAC=00:11:22:33:44:55\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WEBUI_ENV", env)
	if err := os.Mkdir(filepath.Join(dir, "eth0"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "eth0", "address"), []byte("02:11:22:33:44:55\n"), 0600); err != nil {
		t.Fatal(err)
	}
	st := Status{WanIF: "eth0"}
	readMACStatus(&st, dir)
	if st.MACConfigured != "02:11:22:33:44:55" || st.MACCurrent != st.MACConfigured || st.MACPermanent != "00:11:22:33:44:55" {
		t.Fatalf("unexpected status: %+v", st)
	}
	st = Status{WanIF: "../eth0"}
	readMACStatus(&st, dir)
	if st.MACCurrent != "" {
		t.Fatal("unsafe interface accepted")
	}
}
