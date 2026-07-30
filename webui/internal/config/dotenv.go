package config

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func DefaultEnvPath() string {
	if v := os.Getenv("WEBUI_ENV"); v != "" {
		return v
	}
	return "/opt/nanopi-edge/.env"
}

// GetKV читает значение ключа из dotenv (первая совпавшая строка).
func GetKV(path, key string) (string, bool, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", false, nil
		}
		return "", false, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	prefix := key + "="
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, prefix) {
			return strings.Trim(strings.TrimPrefix(line, prefix), `"'`), true, nil
		}
	}
	return "", false, sc.Err()
}

// SetKV пишет или обновляет ключ; остальные строки сохраняет.
func SetKV(path, key, val string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	var lines []string
	if b, err := os.ReadFile(path); err == nil {
		sc := bufio.NewScanner(strings.NewReader(string(b)))
		for sc.Scan() {
			line := sc.Text()
			trim := strings.TrimSpace(line)
			if strings.HasPrefix(trim, key+"=") && !strings.HasPrefix(trim, "#") {
				continue
			}
			lines = append(lines, line)
		}
		if err := sc.Err(); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	val = strings.ReplaceAll(val, "\n", "")
	lines = append(lines, fmt.Sprintf("%s=%s", key, val))
	tmp := path + ".tmp"
	content := strings.Join(lines, "\n")
	if !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	if err := os.WriteFile(tmp, []byte(content), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// DeleteKV удаляет ключ из dotenv.
func DeleteKV(path, key string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var lines []string
	sc := bufio.NewScanner(strings.NewReader(string(b)))
	for sc.Scan() {
		line := sc.Text()
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, key+"=") && !strings.HasPrefix(trim, "#") {
			continue
		}
		lines = append(lines, line)
	}
	if err := sc.Err(); err != nil {
		return err
	}
	tmp := path + ".tmp"
	content := strings.Join(lines, "\n")
	if len(lines) > 0 && !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	if err := os.WriteFile(tmp, []byte(content), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
