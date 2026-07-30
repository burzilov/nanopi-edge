package npmcfg

import "testing"

func TestHomeNetCIDR(t *testing.T) {
	got, err := homeNetCIDR("192.168.1.137")
	if err != nil || got != "192.168.1.0/24" {
		t.Fatalf("got %q %v", got, err)
	}
	if _, err := homeNetCIDR("not-ip"); err == nil {
		t.Fatal("expected error")
	}
}

func TestSkipNeighbor(t *testing.T) {
	if !skipNeighbor("10.10.10.1", "10.10.10.1") {
		t.Fatal("self")
	}
	if skipNeighbor("10.10.10.179", "10.10.10.1") {
		t.Fatal("router should be kept")
	}
	if !skipNeighbor("192.168.1.1", "10.10.10.1") {
		t.Fatal("other /24 skipped")
	}
}
