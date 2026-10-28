package update

import (
	"runtime"
	"strings"
	"testing"
)

func TestWebUIArchiveAssetFor(t *testing.T) {
	cases := map[string]string{
		"amd64": "nanopi-webui-linux-amd64.tar.gz",
		"arm64": "nanopi-webui-linux-arm64.tar.gz",
	}
	for arch, want := range cases {
		if got := WebUIArchiveAssetFor(arch); got != want {
			t.Fatalf("%s: got %q want %q", arch, got, want)
		}
	}
}

func TestWebUIArchiveAssetMatchesRuntime(t *testing.T) {
	want := "nanopi-webui-linux-" + runtime.GOARCH + ".tar.gz"
	if WebUIArchiveAsset != want || WebUIAssetName != want {
		t.Fatalf("WebUIArchiveAsset=%q WebUIAssetName=%q, want %q", WebUIArchiveAsset, WebUIAssetName, want)
	}
}

func fakeRelease(tag string, assets ...string) ghRelease {
	var rel ghRelease
	rel.TagName = tag
	for _, n := range assets {
		rel.Assets = append(rel.Assets, struct {
			Name               string `json:"name"`
			BrowserDownloadURL string `json:"browser_download_url"`
		}{Name: n, BrowserDownloadURL: "https://example.invalid/" + n})
	}
	return rel
}

// Панель проверяет ассет своей архитектуры: релиз только с arm64 для amd64 — не OK.
func TestCheckUsesArchSpecificAsset(t *testing.T) {
	origFetch, origAsset := fetchLatestRelease, WebUIArchiveAsset
	t.Cleanup(func() { fetchLatestRelease, WebUIArchiveAsset = origFetch, origAsset })

	common := []string{WebUIScriptAsset, EdgeScriptAsset, EdgeScriptsAsset}
	armOnly := fakeRelease("v0.1.15", append(common, WebUIArchiveAssetFor("arm64"))...)
	both := fakeRelease("v0.1.15", append(common, WebUIArchiveAssetFor("arm64"), WebUIArchiveAssetFor("amd64"))...)

	for _, tc := range []struct {
		arch   string
		rel    ghRelease
		wantOK bool
	}{
		{"amd64", armOnly, false},
		{"arm64", armOnly, true},
		{"amd64", both, true},
		{"arm64", both, true},
	} {
		rel := tc.rel
		fetchLatestRelease = func(string) (ghRelease, error) { return rel, nil }
		WebUIArchiveAsset = WebUIArchiveAssetFor(tc.arch)
		res, err := Check("owner/repo", "v0.1.14", "v0.1.14")
		if err != nil {
			t.Fatalf("%s: Check: %v", tc.arch, err)
		}
		if res.WebUI.AssetOK != tc.wantOK {
			t.Fatalf("%s: AssetOK=%v want %v (err=%q)", tc.arch, res.WebUI.AssetOK, tc.wantOK, res.WebUI.Error)
		}
		if !tc.wantOK && !strings.Contains(res.WebUI.Error, "linux-"+tc.arch) {
			t.Fatalf("%s: ошибка должна называть ассет своей arch: %q", tc.arch, res.WebUI.Error)
		}
		if tc.wantOK && !res.WebUI.UpdateAvailable {
			t.Fatalf("%s: v0.1.14 → v0.1.15 должно быть update_available", tc.arch)
		}
	}
}
