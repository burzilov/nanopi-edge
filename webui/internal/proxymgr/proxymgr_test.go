package proxymgr

import (
	"testing"

	"nanopi-webui/internal/portfwd"
)

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

func TestWithNPMRulesKeepsOthers(t *testing.T) {
	rules := []portfwd.Rule{
		{ID: "5f1c2a90", Enabled: true, Proto: "tcp", WanPort: 80, DestIP: "10.10.10.179", DestPort: 80, Comment: "nginx-proxy-manager"},
		{ID: "77ab01cd", Enabled: false, Proto: "tcp", WanPort: 443, DestIP: "10.10.10.179", DestPort: 443, Comment: "nginx-proxy-manager"},
		{ID: "0d9e3b11", Enabled: true, Proto: "tcp", WanPort: 5001, DestIP: "10.10.10.179", DestPort: 5001, Comment: "dsm-nas"},
		{ID: "deadbeef", Enabled: true, Proto: "tcp", WanPort: 8080, DestIP: "10.10.10.179", DestPort: 8080, Comment: "nginx-proxy-manager"},
	}
	out := WithNPMRules(rules, "10.10.10.180")
	if len(out) != 3 {
		t.Fatalf("stale NPM rule must be dropped: %+v", out)
	}
	if out[0].ID != "5f1c2a90" || out[1].ID != "77ab01cd" || out[2].ID != "0d9e3b11" {
		t.Fatalf("ids/order must be kept: %+v", out)
	}
	for _, r := range out[:2] {
		if r.DestIP != "10.10.10.180" || !r.Enabled || r.Proto != "tcp" {
			t.Fatalf("NPM rule not updated: %+v", r)
		}
	}
	if out[2].DestIP != "10.10.10.179" || out[2].Comment != "dsm-nas" {
		t.Fatalf("dsm-nas changed: %+v", out[2])
	}
	if err := portfwd.ValidateStore(portfwd.Store{Rules: out}); err != nil {
		t.Fatal(err)
	}

	// Пустой список — добавляются 80 и 443.
	fresh := WithNPMRules([]portfwd.Rule{rules[2]}, "10.10.10.179")
	if len(fresh) != 3 || fresh[1].WanPort != 80 || fresh[2].WanPort != 443 || !portfwd.IsNPM(fresh[2]) {
		t.Fatalf("%+v", fresh)
	}

	left := WithoutNPMRules(rules)
	if len(left) != 1 || left[0].Comment != "dsm-nas" {
		t.Fatalf("disable must keep other rules: %+v", left)
	}
	if n := NPMRules(rules); len(n) != 3 {
		t.Fatalf("%+v", n)
	}
}
