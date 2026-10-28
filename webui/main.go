package main

import (
	"embed"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"os"
	"runtime"
	"strings"

	"nanopi-webui/internal/clash"
	"nanopi-webui/internal/config"
	"nanopi-webui/internal/portfwd"
	"nanopi-webui/internal/update"
	"nanopi-webui/internal/web"
)

// Version задаётся при сборке: -ldflags "-X main.Version=v0.0.1"
var Version = "dev"

//go:embed all:templates
var tmplFS embed.FS

//go:embed all:static
var staticFS embed.FS

func main() {
	if len(os.Args) >= 2 && (os.Args[1] == "--version" || os.Args[1] == "-version" || os.Args[1] == "version") {
		fmt.Printf("nanopi-webui %s %s/%s\n", Version, runtime.GOOS, runtime.GOARCH)
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "--apply-update" {
		if len(os.Args) < 3 || strings.TrimSpace(os.Args[2]) == "" {
			log.Fatal("usage: nanopi-webui --apply-update <tag>")
		}
		os.Exit(update.RunApplyUpdateCLI(os.Args[2]))
	}

	envPath := "/opt/nanopi-edge/.env"
	if v := os.Getenv("WEBUI_ENV"); v != "" {
		envPath = v
	}
	env, err := config.Load(envPath)
	if err != nil {
		log.Fatal(err)
	}

	tmpl, err := template.New("").Funcs(template.FuncMap{
		"AppVersion": func() string { return Version },
	}).ParseFS(tmplFS, "templates/*.html")
	if err != nil {
		log.Fatal(err)
	}

	sub, err := fs.Sub(staticFS, "static")
	if err != nil {
		log.Fatal(err)
	}

	srv := &web.Server{
		Env:      env,
		Clash:    clash.New(env.ClashAPI, env.ClashSecret),
		Tmpl:     tmpl,
		StaticFS: http.FS(sub),
		Version:  Version,
	}

	update.ClearStaleRunning()

	// Новый формат nft-файла проброса (счётчики, ограничение частоты) и смена
	// WAN-интерфейса применяются сами при старте панели, только таблица проброса.
	if changed, err := portfwd.Reconcile(); err != nil {
		log.Printf("port-forwards: не удалось применить правила при старте: %v", err)
	} else if changed {
		log.Printf("port-forwards: nft-правила проброса обновлены по port-forwards.json")
	}

	addr := env.Listen
	log.Printf("nanopi-webui %s listening on http://%s/", Version, addr)
	if err := http.ListenAndServe(addr, srv.Routes()); err != nil {
		log.Fatal(err)
	}
}
