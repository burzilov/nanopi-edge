package wan

import "testing"

func TestApplyRejectsBadVLAN(t *testing.T) {
	err := Apply(ApplyReq{Mode: "pppoe", User: "u", Password: "p", VLAN: "99999"})
	if err == nil {
		t.Fatal("expected VLAN error")
	}
	err = Apply(ApplyReq{Mode: "pppoe", User: "u", Password: "p", VLAN: "abc"})
	if err == nil {
		t.Fatal("expected VLAN error")
	}
	err = Apply(ApplyReq{Mode: "nope"})
	if err == nil {
		t.Fatal("expected mode error")
	}
}
