package web

import (
	"html/template"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func themeTemplates(t *testing.T) *template.Template {
	t.Helper()
	tmpl, err := template.New("").Funcs(template.FuncMap{
		"AppVersion": func() string { return "v9.9.9" },
	}).ParseGlob(filepath.Join("..", "..", "templates", "*.html"))
	if err != nil {
		t.Fatal(err)
	}
	return tmpl
}

// Каждая полная страница подключает общий head: тема до отрисовки и стили.
func TestPagesUseThemeHead(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("..", "..", "templates", "*.html"))
	if err != nil {
		t.Fatal(err)
	}
	pages := 0
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		if !strings.Contains(src, "<!DOCTYPE html>") {
			continue
		}
		pages++
		if !strings.Contains(src, `{{template "head"}}`) {
			t.Errorf("%s: no {{template \"head\"}}", f)
		}
		if strings.Contains(src, `href="/static/app.css"`) {
			t.Errorf("%s: app.css must come from head", f)
		}
		if !strings.Contains(src, `{{template "nav" .}}`) {
			t.Errorf("%s: no nav", f)
		}
	}
	if pages < 6 {
		t.Fatalf("expected at least 6 pages, got %d", pages)
	}
}

func TestThemeHead(t *testing.T) {
	var b strings.Builder
	if err := themeTemplates(t).ExecuteTemplate(&b, "head", nil); err != nil {
		t.Fatal(err)
	}
	head := b.String()
	for _, want := range []string{
		`localStorage.getItem("nanopi-theme")`,
		`setAttribute("data-theme",t)`,
		`<meta name="color-scheme" content="light dark">`,
		`href="/static/app.css?v=v9.9.9"`,
	} {
		if !strings.Contains(head, want) {
			t.Fatalf("head missing %q:\n%s", want, head)
		}
	}
	// Скрипт темы — до стилей, чтобы не было вспышки.
	if strings.Index(head, "nanopi-theme") > strings.Index(head, "app.css") {
		t.Fatal("theme script must precede stylesheet")
	}
}

func TestNavThemeToggle(t *testing.T) {
	var b strings.Builder
	if err := themeTemplates(t).ExecuteTemplate(&b, "nav", nil); err != nil {
		t.Fatal(err)
	}
	nav := b.String()
	for _, want := range []string{
		`class="secondary theme-toggle"`, `aria-label="Тема оформления"`,
		`class="ti ti-auto"`, `class="ti ti-light"`, `class="ti ti-dark"`,
		`/static/theme.js?v=v9.9.9`, `class="brand"`, `hx-post="/sing-box/restart"`,
	} {
		if !strings.Contains(nav, want) {
			t.Fatalf("nav missing %q", want)
		}
	}
}

// Стили и скрипт темы: обе темы, системная по умолчанию, без внешних ресурсов.
func TestThemeStatic(t *testing.T) {
	css, err := os.ReadFile(filepath.Join("..", "..", "static", "app.css"))
	if err != nil {
		t.Fatal(err)
	}
	js, err := os.ReadFile(filepath.Join("..", "..", "static", "theme.js"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		`:root[data-theme="dark"]`, `@media (prefers-color-scheme: dark)`,
		`:root:not([data-theme])`, `--accent:`, `--surface:`,
	} {
		if !strings.Contains(string(css), want) {
			t.Fatalf("app.css missing %q", want)
		}
	}
	for _, want := range []string{`"nanopi-theme"`, `localStorage.setItem`, `localStorage.removeItem`, `aria-label`} {
		if !strings.Contains(string(js), want) {
			t.Fatalf("theme.js missing %q", want)
		}
	}
	for _, src := range [][]byte{css, js} {
		for _, bad := range []string{"http://", "https://", "@import", "url("} {
			if strings.Contains(string(src), bad) {
				t.Fatalf("static must not reference external resources: %q", bad)
			}
		}
	}
}
