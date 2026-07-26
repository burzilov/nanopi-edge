package wan

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultStatusScript = "/opt/nanopi-edge/scripts/wan-status"
	DefaultDHCPScript   = "/opt/nanopi-edge/scripts/wan-dhcp"
	DefaultPPPoEScript  = "/opt/nanopi-edge/scripts/wan-pppoe"
)

type Status struct {
	Mode           string `json:"mode"`
	User           string `json:"user"`
	Password       string `json:"password"`
	VLAN           string `json:"vlan"`
	WanIF          string `json:"wan_if"`
	LanIF          string `json:"lan_if"`
	WanIP          string `json:"wan_ip"`
	LanIP          string `json:"lan_ip"`
	PPP0Up         bool   `json:"ppp0_up"`
	PPP0IP         string `json:"ppp0_ip"`
	LanDHCPLeases  int    `json:"lan_dhcp_leases"`
	LanPPPoEUp     bool   `json:"lan_pppoe_up"`
	LanPPPoEIF     string `json:"lan_pppoe_if"`
	Dnsmasq        string `json:"dnsmasq"`
	PPPoEServer    string `json:"pppoe_server"`
	WanPPPoEUnit   string `json:"wan_pppoe_unit"`
	LastError      string `json:"last_error"`
}

type ApplyReq struct {
	Mode     string `json:"mode"`
	User     string `json:"user"`
	Password string `json:"password"`
	VLAN     string `json:"vlan"`
}

func StatusScript() string {
	if v := os.Getenv("WAN_STATUS_SCRIPT"); v != "" {
		return v
	}
	return DefaultStatusScript
}

func DHCPScript() string {
	if v := os.Getenv("WAN_DHCP_SCRIPT"); v != "" {
		return v
	}
	return DefaultDHCPScript
}

func PPPoEScript() string {
	if v := os.Getenv("WAN_PPPOE_SCRIPT"); v != "" {
		return v
	}
	return DefaultPPPoEScript
}

func GetStatus() (Status, error) {
	cmd := exec.Command(StatusScript())
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return Status{}, fmt.Errorf("wan-status: %w (%s)", err, strings.TrimSpace(stderr.String()))
	}
	var st Status
	if err := json.Unmarshal(stdout.Bytes(), &st); err != nil {
		return Status{}, fmt.Errorf("wan-status json: %w", err)
	}
	return st, nil
}

func Apply(req ApplyReq) error {
	mode := strings.ToLower(strings.TrimSpace(req.Mode))
	switch mode {
	case "dhcp":
		return runScript(DHCPScript())
	case "pppoe":
		vlan := strings.TrimSpace(req.VLAN)
		if vlan != "" {
			n, err := strconv.Atoi(vlan)
			if err != nil || n < 1 || n > 4094 {
				return fmt.Errorf("VLAN должен быть 1–4094 или пусто")
			}
		}
		args := []string{req.User, req.Password}
		if vlan != "" {
			args = append(args, vlan)
		}
		return runScript(PPPoEScript(), args...)
	default:
		return fmt.Errorf("неизвестный mode: %s (dhcp|pppoe)", req.Mode)
	}
}

func runScript(path string, args ...string) error {
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("нет скрипта %s: %w", path, err)
	}
	cmd := exec.Command(path, args...)
	cmd.Env = append(os.Environ(), "NANOPI_YES=1")
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	out := strings.TrimSpace(buf.String())
	if err != nil {
		if out == "" {
			return fmt.Errorf("%s: %w", path, err)
		}
		return fmt.Errorf("%s: %w\n%s", path, err, out)
	}
	// дать pppd чуть времени после Apply
	time.Sleep(400 * time.Millisecond)
	return nil
}
