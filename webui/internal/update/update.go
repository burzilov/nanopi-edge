package update

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	WebUIArchiveAsset = "nanopi-webui-linux-arm64.tar.gz"
	WebUIScriptAsset  = "install-webui.sh"
	EdgeScriptAsset   = "install-singbox.sh"
)

// Legacy name used in older messages / checks for the binary archive.
const WebUIAssetName = WebUIArchiveAsset

type ComponentStatus struct {
	Current         string `json:"current"`
	Latest          string `json:"latest"`
	UpdateAvailable bool   `json:"update_available"`
	AssetOK         bool   `json:"asset_ok"`
	Name            string `json:"name,omitempty"`
	Body            string `json:"body,omitempty"`
	HTMLURL         string `json:"html_url,omitempty"`
	Error           string `json:"error,omitempty"`
}

type CheckResult struct {
	Repo            string          `json:"repo"`
	Latest          string          `json:"latest"`
	UpdateAvailable bool            `json:"update_available"`
	Name            string          `json:"name,omitempty"`
	Body            string          `json:"body,omitempty"`
	HTMLURL         string          `json:"html_url,omitempty"`
	WebUI           ComponentStatus `json:"webui"`
	Edge            ComponentStatus `json:"edge"`
}

type ghRelease struct {
	TagName string `json:"tag_name"`
	Name    string `json:"name"`
	Body    string `json:"body"`
	HTMLURL string `json:"html_url"`
	Assets  []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
	} `json:"assets"`
}

func Normalize(v string) string {
	v = strings.TrimSpace(v)
	return strings.TrimPrefix(v, "v")
}

// CompareSemver returns -1 if a<b, 0 if equal, 1 if a>b. Non-semver → lexical.
func CompareSemver(a, b string) int {
	a, b = Normalize(a), Normalize(b)
	ap := strings.Split(a, ".")
	bp := strings.Split(b, ".")
	for len(ap) < 3 {
		ap = append(ap, "0")
	}
	for len(bp) < 3 {
		bp = append(bp, "0")
	}
	for i := 0; i < 3; i++ {
		ai, _ := strconv.Atoi(ap[i])
		bi, _ := strconv.Atoi(bp[i])
		if ai < bi {
			return -1
		}
		if ai > bi {
			return 1
		}
	}
	return 0
}

func fetchLatest(repo string) (ghRelease, error) {
	return fetchRelease(repo, "")
}

func fetchRelease(repo, tag string) (ghRelease, error) {
	var rel ghRelease
	if repo == "" {
		return rel, fmt.Errorf("WEBUI_GITHUB_REPO пуст")
	}
	var url string
	if tag == "" {
		url = fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", repo)
	} else {
		url = fmt.Sprintf("https://api.github.com/repos/%s/releases/tags/%s", repo, tag)
	}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return rel, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "nanopi-webui")

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return rel, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return rel, err
	}
	if resp.StatusCode != http.StatusOK {
		return rel, fmt.Errorf("GitHub API %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	if err := json.Unmarshal(body, &rel); err != nil {
		return rel, err
	}
	if rel.TagName == "" {
		return rel, fmt.Errorf("в release нет tag_name")
	}
	return rel, nil
}

func assetURL(rel ghRelease, name string) string {
	for _, a := range rel.Assets {
		if a.Name == name {
			return a.BrowserDownloadURL
		}
	}
	return ""
}

func Check(repo, webuiCurrent, edgeCurrent string) (CheckResult, error) {
	out := CheckResult{
		Repo:  repo,
		WebUI: ComponentStatus{Current: webuiCurrent},
		Edge:  ComponentStatus{Current: edgeCurrent},
	}
	if edgeCurrent == "" {
		out.Edge.Current = "unknown"
	}
	rel, err := fetchLatest(repo)
	if err != nil {
		return out, err
	}

	out.Latest = rel.TagName
	out.Name = rel.Name
	out.Body = rel.Body
	out.HTMLURL = rel.HTMLURL

	out.WebUI.Latest = rel.TagName
	out.WebUI.Name = rel.Name
	out.WebUI.Body = rel.Body
	out.WebUI.HTMLURL = rel.HTMLURL
	hasScript := assetURL(rel, WebUIScriptAsset) != ""
	hasArchive := assetURL(rel, WebUIArchiveAsset) != ""
	out.WebUI.AssetOK = hasScript && hasArchive
	switch {
	case !hasScript:
		out.WebUI.Error = fmt.Sprintf("нет ассета %s", WebUIScriptAsset)
	case !hasArchive:
		out.WebUI.Error = fmt.Sprintf("нет ассета %s", WebUIArchiveAsset)
	default:
		out.WebUI.UpdateAvailable = CompareSemver(webuiCurrent, rel.TagName) < 0
	}

	out.Edge.Latest = rel.TagName
	out.Edge.Name = rel.Name
	out.Edge.Body = rel.Body
	out.Edge.HTMLURL = rel.HTMLURL
	out.Edge.AssetOK = assetURL(rel, EdgeScriptAsset) != ""
	if !out.Edge.AssetOK {
		out.Edge.Error = fmt.Sprintf("нет ассета %s", EdgeScriptAsset)
	} else if edgeCurrent == "" || edgeCurrent == "unknown" {
		out.Edge.UpdateAvailable = true
	} else {
		out.Edge.UpdateAvailable = CompareSemver(edgeCurrent, rel.TagName) < 0
	}

	out.UpdateAvailable = out.WebUI.UpdateAvailable || out.Edge.UpdateAvailable
	return out, nil
}

func downloadFile(url, dest string) error {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "nanopi-webui")
	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("download %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dest), ".nanopi-dl-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := io.Copy(tmp, io.LimitReader(resp.Body, 32<<20)); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Chmod(0o755); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, dest)
}

func downloadReleaseAsset(repo, version, assetName, dest string) error {
	rel, err := fetchRelease(repo, version)
	if err != nil {
		return err
	}
	dl := assetURL(rel, assetName)
	if dl == "" {
		return fmt.Errorf("в release %s нет ассета %s", version, assetName)
	}
	return downloadFile(dl, dest)
}

func runBash(script string, env ...string) error {
	cmd := exec.Command("/bin/bash", script)
	cmd.Env = append(os.Environ(), env...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func runBashArgs(script string, args []string, env ...string) error {
	cmd := exec.Command("/bin/bash", append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), env...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// ApplyEdge скачивает install-singbox.sh из release и запускает с NANOPI_YES=1.
func ApplyEdge(repo, version, destScript string) error {
	if destScript == "" {
		destScript = "/opt/nanopi-edge/install-singbox.sh"
	}
	if version == "" {
		return fmt.Errorf("нужен version (tag)")
	}
	if err := downloadReleaseAsset(repo, version, EdgeScriptAsset, destScript); err != nil {
		return err
	}
	return runBash(destScript,
		"NANOPI_YES=1",
		"EDGE_VERSION="+version,
		"WEBUI_GITHUB_REPO="+repo,
		"DEBIAN_FRONTEND=noninteractive",
	)
}

// ApplyWebUI скачивает install-webui.sh из release и запускает --noninteractive.
func ApplyWebUI(destScript, repo, version string) error {
	if destScript == "" {
		destScript = "/opt/nanopi-edge/install-webui.sh"
	}
	if version == "" {
		return fmt.Errorf("нужен version (tag)")
	}
	if err := downloadReleaseAsset(repo, version, WebUIScriptAsset, destScript); err != nil {
		return err
	}
	return runBashArgs(destScript, []string{"--noninteractive"},
		"WEBUI_GITHUB_REPO="+repo,
		"WEBUI_VERSION="+version,
		"DEBIAN_FRONTEND=noninteractive",
	)
}

// Deprecated: use ApplyWebUI.
func Apply(scriptPath, repo, version string) error {
	return ApplyWebUI(scriptPath, repo, version)
}

// ApplyAll: качает оба скрипта, сначала edge, затем webui (рестарт панели последним).
func ApplyAll(repo, version, edgeScript, webuiScript string) error {
	if repo == "" {
		return fmt.Errorf("WEBUI_GITHUB_REPO пуст")
	}
	if version == "" {
		return fmt.Errorf("нужен version (tag)")
	}
	if err := ApplyEdge(repo, version, edgeScript); err != nil {
		return fmt.Errorf("edge: %w", err)
	}
	if err := ApplyWebUI(webuiScript, repo, version); err != nil {
		return fmt.Errorf("webui: %w", err)
	}
	return nil
}
