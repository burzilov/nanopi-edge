package web

import (
	"bufio"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"nanopi-webui/internal/clash"
	"nanopi-webui/internal/config"
	"nanopi-webui/internal/domains"
	"nanopi-webui/internal/logfmt"
	"nanopi-webui/internal/proxymgr"
	"nanopi-webui/internal/sbconfig"
	"nanopi-webui/internal/sysd"
	"nanopi-webui/internal/update"
	"nanopi-webui/internal/wan"
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
	WAN     wan.Status
	WANErr  string
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(s.StaticFS)))
	mux.HandleFunc("GET /{$}", s.handleHome)
	mux.HandleFunc("GET /partials/status", s.handleStatusPartial)
	mux.HandleFunc("GET /partials/wan", s.handleWanPartial)
	mux.HandleFunc("POST /proxy", s.handleProxySet)
	mux.HandleFunc("POST /sing-box/restart", s.handleRestart)
	mux.HandleFunc("GET /logs", s.handleLogs)
	mux.HandleFunc("GET /logs/stream", s.handleLogsStream)
	mux.HandleFunc("GET /domains", s.handleDomainsPage)
	mux.HandleFunc("POST /domains/save-restart", s.handleDomainsSaveRestart)
	mux.HandleFunc("GET /proxy-manager", s.handleProxyManagerPage)
	mux.HandleFunc("POST /proxy-manager", s.handleProxyManagerSave)
	mux.HandleFunc("GET /api/proxy-manager", s.handleAPIProxyManagerGet)
	mux.HandleFunc("GET /config", s.handleConfigPage)
	mux.HandleFunc("POST /config/check", s.handleConfigCheck)
	mux.HandleFunc("POST /config/save-restart", s.handleConfigSaveRestart)
	mux.HandleFunc("GET /api/version", s.handleAPIVersion)
	mux.HandleFunc("GET /api/updates/check", s.handleAPIUpdatesCheck)
	mux.HandleFunc("GET /api/updates/status", s.handleAPIUpdatesStatus)
	mux.HandleFunc("POST /api/updates/apply", s.handleAPIUpdatesApply)
	mux.HandleFunc("GET /api/wan", s.handleAPIWanGet)
	mux.HandleFunc("POST /api/wan", s.handleAPIWanPost)
	mux.HandleFunc("POST /wan", s.handleWanForm)
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
	if st, err := wan.GetStatus(); err != nil {
		d.WANErr = err.Error()
	} else {
		d.WAN = st
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

func (s *Server) handleWanPartial(w http.ResponseWriter, r *http.Request) {
	s.render(w, "partials/wan", s.status())
}

func (s *Server) handleProxySet(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	name := strings.TrimSpace(r.FormValue("name"))
	d := s.status()
	if name == "" {
		d.Error = "не выбран outbound"
		s.render(w, "partials/status", d)
		return
	}
	if err := sbconfig.SetSelectorDefault(s.Env.SingboxConfig, "proxy", name); err != nil {
		d.Error = err.Error()
		s.render(w, "partials/status", d)
		return
	}
	if err := sysd.Restart(s.Env.SingboxUnit); err != nil {
		d.Error = err.Error()
		s.render(w, "partials/status", d)
		return
	}
	sysd.WaitActive(s.Env.SingboxUnit, 15*time.Second)
	_ = s.Clash.WaitReady(20, 500*time.Millisecond)
	d = s.status()
	d.Message = "Выбран VPN-сервер «" + name + "». Настройки сохранены, sing-box перезапущен"
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
	d.Message = "sing-box перезапущен. Интернет мог кратко пропасть — это нормально"
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
	data["Message"] = "Список доменов сохранён, sing-box перезапущен"
	s.render(w, "domains_inner", data)
}

type proxyManagerPageData struct {
	proxymgr.Status
	Message string
	Error   string
}

func (s *Server) proxyManagerData(msg, errMsg string) proxyManagerPageData {
	d := proxyManagerPageData{Message: msg, Error: errMsg}
	st, err := proxymgr.GetStatus()
	if err != nil {
		if d.Error == "" {
			d.Error = err.Error()
		}
		return d
	}
	d.Status = st
	return d
}

func (s *Server) handleProxyManagerPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "proxy_manager", s.proxyManagerData("", ""))
}

func (s *Server) handleProxyManagerSave(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	proxyIP := strings.TrimSpace(r.FormValue("proxy_ip"))
	if err := proxymgr.Apply(proxyIP); err != nil {
		s.render(w, "proxy_manager_inner", s.proxyManagerData("", err.Error()))
		return
	}
	msg := "Обвязка выключена: проброс с интернета и DNS из дома сняты"
	if proxyIP != "" {
		msg = "Готово: с интернета порты 80/443 идут на WAN роутера, из дома DNS ведёт на " + proxyIP
	}
	s.render(w, "proxy_manager_inner", s.proxyManagerData(msg, ""))
}

func (s *Server) handleAPIProxyManagerGet(w http.ResponseWriter, r *http.Request) {
	st, err := proxymgr.GetStatus()
	if err != nil {
		s.writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusOK, st)
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
		data["Message"] = "Проверка прошла успешно — конфиг можно сохранять"
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
	data["Message"] = "Конфиг сохранён, sing-box перезапущен. Интернет мог кратко моргнуть"
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

func (s *Server) handleAPIWanGet(w http.ResponseWriter, r *http.Request) {
	st, err := wan.GetStatus()
	if err != nil {
		s.writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusOK, st)
}

func (s *Server) handleAPIWanPost(w http.ResponseWriter, r *http.Request) {
	var req wan.ApplyReq
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&req); err != nil {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON: " + err.Error()})
		return
	}
	if err := wan.Apply(req); err != nil {
		s.writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	st, err := wan.GetStatus()
	if err != nil {
		s.writeJSON(w, http.StatusOK, map[string]any{"ok": true, "warning": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"ok": true, "status": st})
}

func (s *Server) handleWanForm(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	req := wan.ApplyReq{
		Mode:     r.FormValue("mode"),
		User:     r.FormValue("user"),
		Password: r.FormValue("password"),
		VLAN:     r.FormValue("vlan"),
	}
	d := s.status()
	if err := wan.Apply(req); err != nil {
		d.Error = err.Error()
		s.render(w, "partials/wan", d)
		return
	}
	d = s.status()
	switch strings.ToLower(req.Mode) {
	case "pppoe":
		d.Message = "PPPoE включён — подождите, пока появится сессия у провайдера"
	default:
		d.Message = "Режим DHCP: IP снова выдаёт провайдер автоматически"
	}
	s.render(w, "partials/wan", d)
}

func (s *Server) handleAPIVersion(w http.ResponseWriter, r *http.Request) {
	edgeVer := s.Env.EdgeVersion
	if env, err := config.Load(config.DefaultEnvPath()); err == nil {
		if env.EdgeVersion != "" {
			edgeVer = env.EdgeVersion
			s.Env.EdgeVersion = env.EdgeVersion
		}
	}
	s.writeJSON(w, http.StatusOK, map[string]string{
		"version":      s.Version,
		"edge_version": edgeVer,
		"repo":         s.Env.GithubRepo,
	})
}

func (s *Server) handleAPIUpdatesCheck(w http.ResponseWriter, r *http.Request) {
	if s.Env.GithubRepo == "" {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "в .env нет WEBUI_GITHUB_REPO",
		})
		return
	}
	edgeVer := s.Env.EdgeVersion
	if envPath := os.Getenv("WEBUI_ENV"); envPath != "" {
		if env, err := config.Load(envPath); err == nil {
			if env.EdgeVersion != "" {
				edgeVer = env.EdgeVersion
				s.Env.EdgeVersion = env.EdgeVersion
			}
			if env.InstallEdge != "" {
				s.Env.InstallEdge = env.InstallEdge
			}
		}
	}
	res, err := update.Check(s.Env.GithubRepo, s.Version, edgeVer)
	if err != nil {
		s.writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusOK, res)
}

type applyReq struct {
	Version string `json:"version"`
}

func (s *Server) handleAPIUpdatesStatus(w http.ResponseWriter, r *http.Request) {
	st, err := update.ReadStatus()
	if err != nil {
		s.writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusOK, st)
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
	update.ClearStaleRunning()
	if cur, busy := update.InProgress(); busy {
		s.writeJSON(w, http.StatusConflict, map[string]any{
			"error":   "обновление уже выполняется",
			"status":  cur,
			"version": cur.Version,
		})
		return
	}
	self, err := os.Executable()
	if err != nil {
		s.writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if err := update.StartDetachedApply(self, s.Env.GithubRepo, req.Version, s.Env.InstallEdge, s.Env.InstallWebUI); err != nil {
		s.writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusAccepted, map[string]any{
		"ok":      true,
		"version": req.Version,
		"message": "Фон (detached): edge, затем webui. Статус: GET /api/updates/status",
	})
}

func (s *Server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.Tmpl.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), 500)
	}
}
