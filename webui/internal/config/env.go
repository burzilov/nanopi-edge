package config

import (
	"bufio"
	"os"
	"strings"
)

const DefaultInstallWebUI = "/opt/nanopi-edge/install-webui.sh"

type Env struct {
	ClashAPI      string
	ClashSecret   string
	SingboxConfig string
	SingboxUnit   string
	Listen        string
	GithubRepo    string
	InstallWebUI  string
}

func Load(path string) (Env, error) {
	e := Env{
		ClashAPI:      "http://127.0.0.1:9090",
		SingboxConfig: "/etc/sing-box/config.json",
		SingboxUnit:   "sing-box",
		Listen:        "10.10.10.1:80",
		InstallWebUI:  DefaultInstallWebUI,
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return e, nil
		}
		return e, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		v = strings.Trim(v, `"'`)
		switch strings.TrimSpace(k) {
		case "CLASH_API":
			e.ClashAPI = v
		case "CLASH_SECRET":
			e.ClashSecret = v
		case "SINGBOX_CONFIG":
			e.SingboxConfig = v
		case "SINGBOX_UNIT":
			e.SingboxUnit = v
		case "WEBUI_LISTEN":
			e.Listen = v
		case "WEBUI_GITHUB_REPO":
			e.GithubRepo = v
		case "WEBUI_INSTALL_SCRIPT":
			e.InstallWebUI = v
		}
	}
	if e.InstallWebUI == "" {
		e.InstallWebUI = DefaultInstallWebUI
	}
	return e, sc.Err()
}
