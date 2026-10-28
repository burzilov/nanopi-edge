package listen

import (
	"context"
	"io"
	"net"
	"net/http"
	"runtime"
	"testing"
	"time"
)

func TestListenLoopbackServes(t *testing.T) {
	ln, err := Listen(context.Background(), "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") })}
	go srv.Serve(ln)
	defer srv.Close()
	c := http.Client{Timeout: 3 * time.Second}
	resp, err := c.Get("http://" + ln.Addr().String() + "/")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(b) != "ok" {
		t.Fatalf("body %q", b)
	}
}

// Адрес, которого нет ни на одном интерфейсе (TEST-NET-2): обычный bind даёт
// EADDRNOTAVAIL, с IP_FREEBIND — успех (так панель стартует до router-on).
func TestListenAbsentAddrFreebind(t *testing.T) {
	const addr = "198.51.100.77:0"
	if AddrPresent(addr) {
		t.Skip("198.51.100.77 неожиданно есть на интерфейсе")
	}
	if runtime.GOOS != "linux" {
		t.Skip("IP_FREEBIND только на Linux")
	}
	if _, err := net.Listen("tcp", addr); err == nil {
		t.Log("обычный bind тоже прошёл (net.ipv4.ip_nonlocal_bind=1?)")
	}
	ln, err := Listen(context.Background(), addr)
	if err != nil {
		t.Fatalf("freebind listen: %v", err)
	}
	ln.Close()
}

func TestAddrPresent(t *testing.T) {
	for _, a := range []string{"127.0.0.1:80", "0.0.0.0:80", ":80", "[::]:80", "garbage"} {
		if !AddrPresent(a) {
			t.Errorf("%s: want present", a)
		}
	}
	if AddrPresent("198.51.100.77:80") {
		t.Skip("198.51.100.77 есть на интерфейсе")
	}
}
