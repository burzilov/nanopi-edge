package web

import (
	"encoding/json"
	"html/template"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"nanopi-webui/internal/mobilevless"
)

func TestAPIMobileVlessNoSecrets(t *testing.T) {
	dir := t.TempDir()
	state := filepath.Join(dir, "inbound-vless-reality.json")
	t.Setenv("VLESS_MOBILE_STATE", state)
	t.Setenv("SINGBOX_CONFIG", filepath.Join(dir, "missing-config.json"))
	st := mobilevless.State{
		Enabled: true, Port: 8443, UUID: "secret-uuid", PrivateKey: "secret-pk",
		PublicKey: "pub", ShortID: "sid", HandshakeServer: "www.example.com",
		HandshakePort: 443, ServerName: "www.example.com",
	}
	b, _ := json.Marshal(st)
	if err := os.WriteFile(state, b, 0o600); err != nil {
		t.Fatal(err)
	}

	srv := &Server{Tmpl: template.New("x")}
	req := httptest.NewRequest(http.MethodGet, "/api/mobile-vless", nil)
	rr := httptest.NewRecorder()
	srv.handleAPIMobileVlessGet(rr, req)
	if rr.Code != 200 {
		t.Fatalf("status %d body %s", rr.Code, rr.Body.String())
	}
	body := rr.Body.String()
	for _, leak := range []string{"secret-uuid", "secret-pk", "vless://", "private_key", "uuid"} {
		if strings.Contains(body, leak) {
			t.Fatalf("leak %q in %s", leak, body)
		}
	}
	if !strings.Contains(rr.Header().Get("Cache-Control"), "no-store") {
		t.Fatal("expected Cache-Control: no-store")
	}
}

func TestMobileVlessRoutesRegistered(t *testing.T) {
	tmpl := template.New("t")
	_, _ = tmpl.New("mobile_vless").Parse(`ok`)
	srv := &Server{Tmpl: tmpl}
	h := srv.Routes()
	req := httptest.NewRequest(http.MethodGet, "/mobile-vless", nil)
	rr := httptest.NewRecorder()
	h.ServeHTTP(rr, req)
	// may 500 if template incomplete, but route should not be 404
	if rr.Code == http.StatusNotFound {
		t.Fatal("route missing")
	}
}
