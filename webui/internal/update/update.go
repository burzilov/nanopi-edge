package update

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const AssetName = "nanopi-webui-linux-arm64.tar.gz"

type CheckResult struct {
	Current         string `json:"current"`
	Latest          string `json:"latest"`
	UpdateAvailable bool   `json:"update_available"`
	Name            string `json:"name,omitempty"`
	Body            string `json:"body,omitempty"`
	HTMLURL         string `json:"html_url,omitempty"`
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

func Check(repo, current string) (CheckResult, error) {
	out := CheckResult{Current: current}
	if repo == "" {
		return out, fmt.Errorf("WEBUI_GITHUB_REPO пуст")
	}
	url := fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", repo)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return out, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "nanopi-webui")

	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return out, err
	}
	if resp.StatusCode != http.StatusOK {
		return out, fmt.Errorf("GitHub API %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}
	var rel ghRelease
	if err := json.Unmarshal(body, &rel); err != nil {
		return out, err
	}
	if rel.TagName == "" {
		return out, fmt.Errorf("в latest release нет tag_name")
	}
	hasAsset := false
	for _, a := range rel.Assets {
		if a.Name == AssetName {
			hasAsset = true
			break
		}
	}
	if !hasAsset {
		return out, fmt.Errorf("в release %s нет ассета %s", rel.TagName, AssetName)
	}
	out.Latest = rel.TagName
	out.Name = rel.Name
	out.Body = rel.Body
	out.HTMLURL = rel.HTMLURL
	out.UpdateAvailable = CompareSemver(current, rel.TagName) < 0
	return out, nil
}

// Apply запускает install-webui.sh --noninteractive для указанного tag (или latest если version пуст).
func Apply(scriptPath, repo, version string) error {
	if scriptPath == "" {
		return fmt.Errorf("путь к install-webui.sh пуст")
	}
	if _, err := os.Stat(scriptPath); err != nil {
		return fmt.Errorf("нет скрипта %s: %w", scriptPath, err)
	}
	if repo == "" {
		return fmt.Errorf("WEBUI_GITHUB_REPO пуст")
	}
	cmd := exec.Command("/bin/bash", scriptPath, "--noninteractive")
	cmd.Env = append(os.Environ(),
		"WEBUI_GITHUB_REPO="+repo,
		"WEBUI_VERSION="+version,
		"DEBIAN_FRONTEND=noninteractive",
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
