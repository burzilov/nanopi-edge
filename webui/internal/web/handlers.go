package web

import (
	"bufio"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"nanopi-webui/internal/clash"
	"nanopi-webui/internal/config"
	"nanopi-webui/internal/domains"
	"nanopi-webui/internal/logfmt"
	"nanopi-webui/internal/sysd"
	"nanopi-webui/internal/update"
)

type Server struct {
	Env      config.Env
	Clash    *clash.Client
	Tmpl     *template.Template
	StaticFS http.FileSystem
	Version  string
}

type statusData struct {
	Active  string
	Proxy   string
	All     []string
	Uptime  string
	Message string
	Error   string
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(s.StaticFS)))
	mux.HandleFunc("GET /{$}", s.handleHome)
	mux.HandleFunc("GET /partials/status", s.handleStatusPartial)
	mux.HandleFunc("POST /proxy", s.handleProxySet)
	mux.HandleFunc("POST /sing-box/restart", s.handleRestart)
	mux.HandleFunc("GET /logs", s.handleLogs)
	mux.HandleFunc("GET /logs/stream", s.handleLogsStream)
	mux.HandleFunc("GET /domains", s.handleDomainsPage)
	mux.HandleFunc("POST /domains/save-restart", s.handleDomainsSaveRestart)
	mux.HandleFunc("GET /config", s.handleConfigPage)
	mux.HandleFunc("POST /config/check", s.handleConfigCheck)
	mux.HandleFunc("POST /config/save-restart", s.handleConfigSaveRestart)
	mux.HandleFunc("GET /api/version", s.handleAPIVersion)
	mux.HandleFunc("GET /api/updates/check", s.handleAPIUpdatesCheck)
	mux.HandleFunc("POST /api/updates/apply", s.handleAPIUpdatesApply)
	return mux
}

func (s *Server) handleHome(w http.ResponseWriter, r *http.Request) {
	s.render(w, "home", nil)
}

func ruActive(s string) string {
	switch s {
	case "active":
		return "работает"
	case "inactive":
		return "остановлен"
	case "failed":
		return "ошибка"
	case "activating":
		return "запускается"
	case "deactivating":
		return "останавливается"
	default:
		return s
	}
}

func (s *Server) status() statusData {
	d := statusData{
		Active: ruActive(sysd.IsActive(s.Env.SingboxUnit)),
		Uptime: sysd.ProcessUptime(s.Env.SingboxUnit),
	}
	_ = s.Clash.WaitReady(5, 200*time.Millisecond)
	g, err := s.Clash.GetProxy("proxy")
	if err != nil {
		d.Error = err.Error()
		d.Proxy = "—"
		return d
	}
	d.Proxy = g.Now
	d.All = g.All
	return d
}

func (s *Server) handleStatusPartial(w http.ResponseWriter, r *http.Request) {
	s.render(w, "partials/status", s.status())
}

func (s *Server) handleProxySet(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	name := r.FormValue("name")
	d := s.status()
	if err := s.Clash.WaitReady(10, 500*time.Millisecond); err != nil {
		d.Error = err.Error()
		s.render(w, "partials/status", d)
		return
	}
	if err := s.Clash.SetProxy("proxy", name); err != nil {
		d.Error = err.Error()
		s.render(w, "partials/status", d)
		return
	}
	d = s.status()
	d.Message = "Выбран: " + name
	s.render(w, "partials/status", d)
}

func (s *Server) handleRestart(w http.ResponseWriter, r *http.Request) {
	d := statusData{}
	if err := sysd.Restart(s.Env.SingboxUnit); err != nil {
		d.Error = err.Error()
		s.render(w, "partials/flash", d)
		return
	}
	sysd.WaitActive(s.Env.SingboxUnit, 15*time.Second)
	_ = s.Clash.WaitReady(20, 500*time.Millisecond)
	d.Message = "sing-box перезапущен (TUN мог кратко оборваться)"
	s.render(w, "partials/flash", d)
}

func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	text, err := sysd.JournalTail(s.Env.SingboxUnit, 200)
	data := map[string]any{"LogsHTML": logfmt.BlockHTML(text), "Error": ""}
	if err != nil {
		data["Error"] = err.Error()
	}
	s.render(w, "logs", data)
}

func (s *Server) handleLogsStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", 500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	cmd, err := sysd.JournalFollow(s.Env.SingboxUnit)
	if err != nil {
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", err.Error())
		flusher.Flush()
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", err.Error())
		flusher.Flush()
		return
	}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(w, "event: error\ndata: %s\n\n", err.Error())
		flusher.Flush()
		return
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		select {
		case <-r.Context().Done():
			return
		default:
		}
		line := logfmt.CleanLine(sc.Text())
		if line == "" {
			continue
		}
		// SSE: одна строка data без сырых переносов
		line = strings.ReplaceAll(line, "\n", " ")
		fmt.Fprintf(w, "data: %s\n\n", line)
		flusher.Flush()
	}
}

func (s *Server) handleDomainsPage(w http.ResponseWriter, r *http.Request) {
	data := map[string]any{
		"Text":    "",
		"Message": "",
		"Error":   "",
	}
	cfgBytes, err := os.ReadFile(s.Env.SingboxConfig)
	if err != nil {
		data["Error"] = err.Error()
		s.render(w, "domains", data)
		return
	}
	list, err := domains.ExtractProxyDomains(cfgBytes)
	if err != nil {
		data["Error"] = err.Error()
	} else {
		data["Text"] = strings.Join(list, "\n")
	}
	s.render(w, "domains", data)
}

func parseDomainText(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	return out
}

func (s *Server) handleDomainsSaveRestart(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	list := parseDomainText(r.FormValue("domains"))
	data := map[string]any{"Text": strings.Join(list, "\n"), "Message": "", "Error": ""}

	cfgBytes, err := os.ReadFile(s.Env.SingboxConfig)
	if err != nil {
		data["Error"] = err.Error()
		s.render(w, "domains_inner", data)
		return
	}
	merged, err := domains.MergeProxyDomains(cfgBytes, list)
	if err != nil {
		data["Error"] = err.Error()
		s.render(w, "domains_inner", data)
		return
	}
	merged = append(merged, '\n')
	tmp, err := os.CreateTemp("/tmp", "singbox-check-*.json")
	if err != nil {
		data["Error"] = err.Error()
		s.render(w, "domains_inner", data)
		return
	}
	tmpPath := tmp.Name()
	_, _ = tmp.Write(merged)
	_ = tmp.Close()
	defer os.Remove(tmpPath)

	out, err := sysd.SingboxCheck(tmpPath)
	if err != nil {
		data["Error"] = "check failed: " + err.Error() + "\n" + out
		s.render(w, "domains_inner", data)
		return
	}
	if err := atomicWrite(s.Env.SingboxConfig, merged, 0o600); err != nil {
		data["Error"] = err.Error()
		s.render(w, "domains_inner", data)
		return
	}
	if err := sysd.Restart(s.Env.SingboxUnit); err != nil {
		data["Error"] = "restart: " + err.Error()
		s.render(w, "domains_inner", data)
		return
	}
	sysd.WaitActive(s.Env.SingboxUnit, 15*time.Second)
	data["Message"] = "Домены применены в config.json, sing-box перезапущен"
	s.render(w, "domains_inner", data)
}

func (s *Server) handleConfigPage(w http.ResponseWriter, r *http.Request) {
	b, err := os.ReadFile(s.Env.SingboxConfig)
	data := map[string]any{"Config": string(b), "Message": "", "Error": "", "CheckOut": ""}
	if err != nil {
		data["Error"] = err.Error()
		data["Config"] = ""
	}
	s.render(w, "config", data)
}

func (s *Server) handleConfigCheck(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	body := r.FormValue("config")
	data := map[string]any{"Config": body, "Message": "", "Error": "", "CheckOut": ""}
	tmp, err := os.CreateTemp("/tmp", "singbox-check-*.json")
	if err != nil {
		data["Error"] = err.Error()
		s.render(w, "config_inner", data)
		return
	}
	tmpPath := tmp.Name()
	_, _ = tmp.WriteString(body)
	_ = tmp.Close()
	defer os.Remove(tmpPath)
	out, err := sysd.SingboxCheck(tmpPath)
	data["CheckOut"] = out
	if err != nil {
		data["Error"] = "check failed: " + err.Error()
	} else {
		data["Message"] = "check OK"
	}
	s.render(w, "config_inner", data)
}

func (s *Server) handleConfigSaveRestart(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	body := r.FormValue("config")
	data := map[string]any{"Config": body, "Message": "", "Error": "", "CheckOut": ""}
	// validate JSON
	var js any
	if err := json.Unmarshal([]byte(body), &js); err != nil {
		data["Error"] = "invalid JSON: " + err.Error()
		s.render(w, "config_inner", data)
		return
	}
	tmp, err := os.CreateTemp("/tmp", "singbox-check-*.json")
	if err != nil {
		data["Error"] = err.Error()
		s.render(w, "config_inner", data)
		return
	}
	tmpPath := tmp.Name()
	content := []byte(body)
	if !strings.HasSuffix(body, "\n") {
		content = append(content, '\n')
	}
	_, _ = tmp.Write(content)
	_ = tmp.Close()
	defer os.Remove(tmpPath)
	out, err := sysd.SingboxCheck(tmpPath)
	data["CheckOut"] = out
	if err != nil {
		data["Error"] = "check failed: " + err.Error()
		s.render(w, "config_inner", data)
		return
	}
	if err := atomicWrite(s.Env.SingboxConfig, content, 0o600); err != nil {
		data["Error"] = err.Error()
		s.render(w, "config_inner", data)
		return
	}
	if err := sysd.Restart(s.Env.SingboxUnit); err != nil {
		data["Error"] = "restart: " + err.Error()
		s.render(w, "config_inner", data)
		return
	}
	sysd.WaitActive(s.Env.SingboxUnit, 15*time.Second)
	data["Message"] = "Конфиг сохранён, sing-box перезапущен"
	s.render(w, "config_inner", data)
}

func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, path)
}

func (s *Server) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) handleAPIVersion(w http.ResponseWriter, r *http.Request) {
	s.writeJSON(w, http.StatusOK, map[string]string{
		"version": s.Version,
		"repo":    s.Env.GithubRepo,
	})
}

func (s *Server) handleAPIUpdatesCheck(w http.ResponseWriter, r *http.Request) {
	if s.Env.GithubRepo == "" {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "в .env нет WEBUI_GITHUB_REPO",
		})
		return
	}
	res, err := update.Check(s.Env.GithubRepo, s.Version)
	if err != nil {
		s.writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusOK, res)
}

type applyReq struct {
	Version string `json:"version"`
}

func (s *Server) handleAPIUpdatesApply(w http.ResponseWriter, r *http.Request) {
	var req applyReq
	_ = json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&req)
	if req.Version == "" {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "нужен version (tag)"})
		return
	}
	if s.Env.GithubRepo == "" {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "в .env нет WEBUI_GITHUB_REPO",
		})
		return
	}
	// Сразу отвечаем: скрипт перезапустит сервис и оборвёт соединение.
	s.writeJSON(w, http.StatusAccepted, map[string]any{
		"ok":         true,
		"restarting": true,
		"version":    req.Version,
		"message":    "Запускаю install-webui.sh; панель перезапустится",
	})
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	go func() {
		time.Sleep(800 * time.Millisecond)
		if err := update.Apply(s.Env.InstallWebUI, s.Env.GithubRepo, req.Version); err != nil {
			log.Printf("webui update apply failed: %v", err)
		}
	}()
}

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.Tmpl.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), 500)
	}
}
