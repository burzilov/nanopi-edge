package sysd

import (
	"bytes"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

func IsActive(unit string) string {
	out, err := exec.Command("systemctl", "is-active", unit).CombinedOutput()
	s := strings.TrimSpace(string(out))
	if err != nil && s == "" {
		return "unknown"
	}
	return s
}

func Restart(unit string) error {
	cmd := exec.Command("systemctl", "restart", unit)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("systemctl restart %s: %w (%s)", unit, err, buf.String())
	}
	return nil
}

func MainPID(unit string) (string, error) {
	out, err := exec.Command("systemctl", "show", "-p", "MainPID", "--value", unit).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func ProcessUptime(unit string) string {
	pid, err := MainPID(unit)
	if err != nil || pid == "" || pid == "0" {
		return "—"
	}
	out, err := exec.Command("ps", "-o", "etime=", "-p", pid).Output()
	if err != nil {
		return "—"
	}
	return strings.TrimSpace(string(out))
}

func JournalTail(unit string, lines int) (string, error) {
	cmd := exec.Command("journalctl", "-u", unit, "-n", fmt.Sprintf("%d", lines), "--no-pager", "-o", "cat")
	cmd.Env = append(cmd.Environ(), "SYSTEMD_COLORS=0")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func JournalFollow(unit string) (*exec.Cmd, error) {
	cmd := exec.Command("journalctl", "-u", unit, "-f", "-n", "0", "-o", "cat")
	cmd.Env = append(cmd.Environ(), "SYSTEMD_COLORS=0")
	return cmd, nil
}

func SingboxCheck(configPath string) (string, error) {
	cmd := exec.Command("sing-box", "check", "-c", configPath)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func WaitActive(unit string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if IsActive(unit) == "active" {
			return true
		}
		time.Sleep(300 * time.Millisecond)
	}
	return IsActive(unit) == "active"
}
