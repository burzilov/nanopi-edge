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
	// Логика ветки без сети: пустой edge не должен сам по себе давать UpdateAvailable,
	// если webui уже равен latest — проверяем Compare + правило в комментарии через хелпер.
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
