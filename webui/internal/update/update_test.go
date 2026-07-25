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
