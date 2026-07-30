package mobilevless

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateSettings(t *testing.T) {
	err := ValidateSettings(Settings{Port: 443, HandshakeServer: "a.com", HandshakePort: 443, ServerName: "a.com"})
	if err == nil || !strings.Contains(err.Error(), "80 и 443") {
		t.Fatalf("expected 80/443 error, got %v", err)
	}
	err = ValidateSettings(Settings{Port: 8443, HandshakeServer: "", HandshakePort: 443, ServerName: "a.com"})
	if err == nil {
		t.Fatal("expected empty handshake error")
	}
	if err := ValidateSettings(Settings{Port: 8443, HandshakeServer: "a.com", HandshakePort: 443, ServerName: "a.com"}); err != nil {
		t.Fatal(err)
	}
}

func TestMergeInboundInsertReplaceRemove(t *testing.T) {
	base := []byte(`{
  "inbounds": [
    {"type":"tun","tag":"tun-in","interface_name":"sb-tun"}
  ],
  "outbounds": [{"type":"direct","tag":"direct"}],
  "route": {"rules": [{"action":"route","outbound":"direct"}], "final":"direct"}
}`)
	st := State{
		Enabled: true, Port: 8443, UUID: "11111111-1111-1111-1111-111111111111",
		PrivateKey: "priv", PublicKey: "pub", ShortID: "abcd",
		HandshakeServer: "www.example.com", HandshakePort: 443, ServerName: "www.example.com",
	}
	merged, err := MergeInbound(base, st)
	if err != nil {
		t.Fatal(err)
	}
	if !HasInbound(merged) {
		t.Fatal("expected inbound present")
	}
	var root map[string]any
	if err := json.Unmarshal(merged, &root); err != nil {
		t.Fatal(err)
	}
	inbounds := root["inbounds"].([]any)
	if len(inbounds) != 2 {
		t.Fatalf("want 2 inbounds, got %d", len(inbounds))
	}
	// outbounds untouched
	outs := root["outbounds"].([]any)
	if len(outs) != 1 {
		t.Fatal("outbounds changed")
	}
	// replace port
	st.Port = 8444
	merged2, err := MergeInbound(merged, st)
	if err != nil {
		t.Fatal(err)
	}
	var root2 map[string]any
	_ = json.Unmarshal(merged2, &root2)
	inbounds2 := root2["inbounds"].([]any)
	if len(inbounds2) != 2 {
		t.Fatalf("want still 2, got %d", len(inbounds2))
	}
	found := false
	for _, raw := range inbounds2 {
		ob := raw.(map[string]any)
		if ob["tag"] == InboundTag {
			found = true
			if int(ob["listen_port"].(float64)) != 8444 {
				t.Fatalf("port not updated: %v", ob["listen_port"])
			}
		}
	}
	if !found {
		t.Fatal("inbound missing after replace")
	}
	// remove
	removed, err := MergeInbound(merged2, State{Enabled: false})
	if err != nil {
		t.Fatal(err)
	}
	if HasInbound(removed) {
		t.Fatal("expected removed")
	}
	var root3 map[string]any
	_ = json.Unmarshal(removed, &root3)
	if len(root3["inbounds"].([]any)) != 1 {
		t.Fatal("tun should remain")
	}
}

func TestMergeInboundPortConflict(t *testing.T) {
	base := []byte(`{
  "inbounds": [
    {"type":"tun","tag":"tun-in"},
    {"type":"mixed","tag":"mixed-in","listen_port":8443}
  ]
}`)
	st := State{
		Enabled: true, Port: 8443, UUID: "u", PrivateKey: "p", ShortID: "s",
		HandshakeServer: "x", HandshakePort: 443, ServerName: "x",
	}
	_, err := MergeInbound(base, st)
	if err == nil || !strings.Contains(err.Error(), "занят") {
		t.Fatalf("expected conflict, got %v", err)
	}
}

func TestBuildURI(t *testing.T) {
	st := State{
		UUID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", Port: 8443,
		PublicKey: "PubKey", ShortID: "deadbeef", ServerName: "www.example.com",
		Label: "phone",
	}
	uri := BuildURI(st, "203.0.113.10")
	if !strings.HasPrefix(uri, "vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@203.0.113.10:8443?") {
		t.Fatalf("bad prefix: %s", uri)
	}
	for _, want := range []string{"security=reality", "pbk=PubKey", "sid=deadbeef", "sni=www.example.com", "flow=xtls-rprx-vision", "fp=chrome", "type=tcp"} {
		if !strings.Contains(uri, want) {
			t.Fatalf("missing %s in %s", want, uri)
		}
	}
}

func TestSaveLoadState(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "inbound-vless-reality.json")
	t.Setenv("VLESS_MOBILE_STATE", path)
	st := State{
		Enabled: true, Port: 8443, UUID: "u", PrivateKey: "priv", PublicKey: "pub",
		ShortID: "sid", HandshakeServer: "www.example.com", HandshakePort: 443,
		ServerName: "www.example.com", Label: "mobile",
	}
	if err := saveState(st); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("want 0600, got %o", info.Mode().Perm())
	}
	got, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if got.UUID != "u" || got.PrivateKey != "priv" || !got.Enabled {
		t.Fatalf("bad load: %+v", got)
	}
}

func TestWarnIfInboundMissing(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("VLESS_MOBILE_STATE", filepath.Join(dir, "st.json"))
	_ = saveState(State{Enabled: true, UUID: "u", Port: 8443})
	cfg := []byte(`{"inbounds":[{"tag":"tun-in"}]}`)
	msg := WarnIfInboundMissing(cfg)
	if msg == "" {
		t.Fatal("expected warning")
	}
	cfg2, _ := MergeInbound(cfg, State{
		Enabled: true, Port: 8443, UUID: "u", PrivateKey: "p", ShortID: "s",
		HandshakeServer: "x", HandshakePort: 443, ServerName: "x",
	})
	if WarnIfInboundMissing(cfg2) != "" {
		t.Fatal("no warning when present")
	}
}

func TestQRDataURI(t *testing.T) {
	uri := "vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@203.0.113.10:8443?security=reality"
	got, err := QRDataURI(uri)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(got, "data:image/png;base64,") {
		t.Fatalf("bad data uri: %s", got[:40])
	}
}

func TestBuildInboundShape(t *testing.T) {
	st := State{
		Port: 8443, UUID: "uuid", PrivateKey: "pk", ShortID: "sid",
		HandshakeServer: "www.cloudflare.com", HandshakePort: 443, ServerName: "www.cloudflare.com",
	}
	ob := BuildInbound(st)
	if ob["tag"] != InboundTag || ob["listen"] != "0.0.0.0" {
		t.Fatalf("%v", ob)
	}
	tls := ob["tls"].(map[string]any)
	reality := tls["reality"].(map[string]any)
	hs := reality["handshake"].(map[string]any)
	if hs["server"] != "www.cloudflare.com" {
		t.Fatal(hs)
	}
	sids := reality["short_id"].([]any)
	if sids[0] != "sid" {
		t.Fatal(sids)
	}
}
