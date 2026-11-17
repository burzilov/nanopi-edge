package web

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWanMACEndpoint(t *testing.T) {
	dir := t.TempDir()
	output := filepath.Join(dir, "args")
	script := filepath.Join(dir, "mac")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n%s' \"$#\" \"$1\" > \"$MAC_TEST_OUTPUT\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WAN_MAC_SCRIPT", script)
	t.Setenv("MAC_TEST_OUTPUT", output)
	t.Setenv("WAN_STATUS_SCRIPT", filepath.Join(dir, "missing"))
	h := (&Server{}).Routes()

	for _, path := range []string{"/wan/mac", "/api/wan/mac"} {
		t.Run(path, func(t *testing.T) {
			for _, tc := range []struct {
				body      string
				wantArgs  string
				code      int
				wantScript bool
			}{
				{`{"mac":"02:AA:BB:CC:DD:EE"}`, "1\n02:aa:bb:cc:dd:ee", 200, true},
				{`{"mac":""}`, "1\n", 200, true},
				{`{"mac":"01:00:00:00:00:01"}`, "", 400, false},
				{`{}`, "", 400, false},
				{`{"mac":null}`, "", 400, false},
				{`{"mac":""} {}`, "", 400, false},
			} {
				_ = os.Remove(output)
				rr := httptest.NewRecorder()
				h.ServeHTTP(rr, httptest.NewRequest(http.MethodPost, path, strings.NewReader(tc.body)))
				if rr.Code != tc.code {
					t.Fatalf("%s: %d: %s", tc.body, rr.Code, rr.Body.String())
				}
				b, err := os.ReadFile(output)
				if tc.wantScript {
					if err != nil || string(b) != tc.wantArgs {
						t.Fatalf("%s: args %q, %v", tc.body, b, err)
					}
				} else if !os.IsNotExist(err) {
					t.Fatalf("%s: script should not run, got %q", tc.body, b)
				}
				if !strings.Contains(rr.Header().Get("Content-Type"), "application/json") {
					t.Fatal("expected JSON")
				}
			}
		})
	}
}
