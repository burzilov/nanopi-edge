package logfmt

import (
	"html"
	"html/template"
	"regexp"
	"strings"
)

var (
	ansiRe          = regexp.MustCompile(`\x1b\[[0-9;]*m`)
	journalPrefixRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\S+\s+\S+\s+\S+:\s+`)
	tzPrefixRe      = regexp.MustCompile(`^[+-]\d{4}\s+`)
	connIDRe        = regexp.MustCompile(`\s*\[\d+\s+([0-9.]+s)\]\s*`)
	spaceRe         = regexp.MustCompile(`\s{2,}`)
	errorWordRe     = regexp.MustCompile(`\bERROR\b`)
)

// CleanLine убирает journal-префикс, +0300, ANSI и id соединения (длительность оставляет).
func CleanLine(line string) string {
	line = ansiRe.ReplaceAllString(line, "")
	line = journalPrefixRe.ReplaceAllString(line, "")
	line = tzPrefixRe.ReplaceAllString(line, "")
	line = connIDRe.ReplaceAllString(line, " [$1] ")
	line = spaceRe.ReplaceAllString(line, " ")
	return strings.TrimSpace(line)
}

func highlight(escaped string) string {
	return errorWordRe.ReplaceAllString(escaped, `<span class="log-level-error">ERROR</span>`)
}

// LineHTML — одна строка лога как HTML-элемент.
func LineHTML(line string) template.HTML {
	c := CleanLine(line)
	if c == "" {
		return ""
	}
	return template.HTML(`<div class="log-line">` + highlight(html.EscapeString(c)) + `</div>`)
}

// BlockHTML — хвост journal (хронологический снизу вверх → свежие сверху).
func BlockHTML(raw string) template.HTML {
	raw = strings.TrimRight(raw, "\n")
	if raw == "" {
		return ""
	}
	lines := strings.Split(raw, "\n")
	var b strings.Builder
	for i := len(lines) - 1; i >= 0; i-- {
		h := LineHTML(lines[i])
		if h != "" {
			b.WriteString(string(h))
		}
	}
	return template.HTML(b.String())
}
