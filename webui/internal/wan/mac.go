package wan

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"nanopi-webui/internal/config"
)

const DefaultMACScript = "/opt/nanopi-edge/scripts/wan-mac"

var macPattern = regexp.MustCompile(`(?i)^[0-9a-f]{2}(:[0-9a-f]{2}){5}$`)

// NormalizeMAC accepts an empty address as a reset request.
func NormalizeMAC(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", nil
	}
	if !macPattern.MatchString(value) {
		return "", fmt.Errorf("MAC должен быть вида aa:bb:cc:dd:ee:ff")
	}
	mac, err := net.ParseMAC(value)
	if err != nil || len(mac) != 6 {
		return "", fmt.Errorf("MAC должен быть вида aa:bb:cc:dd:ee:ff")
	}
	if mac.String() == "00:00:00:00:00:00" {
		return "", fmt.Errorf("MAC не может быть нулевым")
	}
	if mac[0]&1 != 0 {
		return "", fmt.Errorf("MAC должен быть unicast (не multicast)")
	}
	return mac.String(), nil
}

func ApplyMAC(value string) error {
	mac, err := NormalizeMAC(value)
	if err != nil {
		return err
	}
	path := os.Getenv("WAN_MAC_SCRIPT")
	if path == "" {
		path = DefaultMACScript
	}
	return runScript(path, false, mac)
}

func readMACStatus(st *Status, sysfs string) {
	st.MACConfigured, _, _ = config.GetKV(config.DefaultEnvPath(), "WAN_MAC")
	st.MACPermanent, _, _ = config.GetKV(config.DefaultEnvPath(), "WAN_PERMANENT_MAC")
	iface := st.WanIF
	if iface == "" || iface == "." || iface == ".." || strings.ContainsAny(iface, `/\`) {
		return
	}
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(sysfs, iface, name))
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
	st.MACCurrent = read("address")
	if st.MACPermanent == "" {
		st.MACPermanent = read("perm_address")
	}
}
