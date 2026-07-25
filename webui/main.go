package main

import (
	"embed"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"os"

	"nanopi-webui/internal/clash"
	"nanopi-webui/internal/config"
	"nanopi-webui/internal/web"
)

// Version задаётся при сборке: -ldflags "-X main.Version=v0.0.1"
var Version = "dev"

//go:embed all:templates
var tmplFS embed.FS

//go:embed all:static
var staticFS embed.FS

func main() {
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

	addr := env.Listen
	log.Printf("nanopi-webui %s listening on http://%s/", Version, addr)
	if err := http.ListenAndServe(addr, srv.Routes()); err != nil {
		log.Fatal(err)
	}
}
