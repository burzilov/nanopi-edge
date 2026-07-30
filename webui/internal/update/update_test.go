package update

import "testing"

func TestCompareSemver(t *testing.T) {
	if CompareSemver("v0.0.1", "v0.0.2") >= 0 {
		t.Fatal("0.0.1 should be < 0.0.2")
	}
	if CompareSemver("0.1.0", "v0.1.0") != 0 {
		t.Fatal("equal")
	}
	if CompareSemver("v1.0.0", "0.9.9") <= 0 {
		t.Fatal("1.0.0 > 0.9.9")
	}
}

func TestCheckUnknownEdgeNotUpdate(t *testing.T) {
	webuiCurrent := "v0.0.8"
	latest := "v0.0.8"
	webuiUp := CompareSemver(webuiCurrent, latest) < 0
	edgeCurrent := ""
	edgeUp := false
	if edgeCurrent != "" && edgeCurrent != "unknown" {
		edgeUp = CompareSemver(edgeCurrent, latest) < 0
	}
	if webuiUp || edgeUp {
		t.Fatal("same tag + empty edge must not be update_available")
	}
}

func TestStaleEdgeLabelNoUpdateButton(t *testing.T) {
	// WebUI уже на latest, EDGE_VERSION отстаёт — кнопку не показываем.
	webuiUp := CompareSemver("v0.0.14", "v0.0.14") < 0
	edgeBehind := CompareSemver("v0.0.9", "v0.0.14") < 0
	updateAvail := webuiUp // как в Check: только WebUI
	if !edgeBehind {
		t.Fatal("edge should be behind")
	}
	if updateAvail {
		t.Fatal("update button must not show when only edge label is stale")
	}
}
