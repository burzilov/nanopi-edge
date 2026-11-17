package web

import (
	"bytes"
	"html/template"
	"strings"
	"testing"

	"nanopi-webui/internal/wan"
)

func TestWANStatusTemplate(t *testing.T) {
	tmpl, err := template.ParseFiles("../../templates/partials_wan_status.html")
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name   string
		data   statusData
		want   []string
		absent []string
	}{
		{"pppoe connected", statusData{WAN: wan.Status{Mode: "pppoe", PPP0Up: true, PPP0IP: "192.0.2.1", LastError: "old error"}}, []string{`class="pill ok">Подключено: 192.0.2.1`}, []string{"old error", "Нет подключения"}},
		{"pppoe waiting for address", statusData{WAN: wan.Status{Mode: "pppoe", PPP0Up: true, LastError: "diagnostic"}}, []string{`class="pill bad">Нет подключения`, "Адрес ещё ожидается или подключение не удалось", "Недавняя диагностика PPPoE", "diagnostic"}, []string{"Подключено:"}},
		{"pppoe down with stale address", statusData{WAN: wan.Status{Mode: "pppoe", PPP0IP: "192.0.2.1"}}, []string{`class="pill bad">Нет подключения`}, []string{"Подключено:", "192.0.2.1"}},
		{"pppoe down without address", statusData{WAN: wan.Status{Mode: "pppoe"}}, []string{"Нет подключения", "Адрес ещё ожидается или подключение не удалось"}, []string{"Подключено:", "Недавняя диагностика"}},
		{"dhcp connected", statusData{WAN: wan.Status{Mode: "dhcp", WanIP: "192.0.2.2", LastError: "old error"}}, []string{`class="pill ok">Подключено: 192.0.2.2`}, []string{"old error", "Нет подключения"}},
		{"dhcp waiting", statusData{WAN: wan.Status{Mode: "dhcp", LastError: "old error"}}, []string{`class="pill bad">Нет подключения`, "Адрес ещё ожидается или подключение не удалось"}, []string{"Подключено:", "old error"}},
		{"status error", statusData{WANErr: "status failed", WAN: wan.Status{Mode: "dhcp", WanIP: "192.0.2.2"}}, []string{"Не удалось получить состояние WAN", "status failed"}, []string{"Подключение DHCP", "Подключено:", "192.0.2.2"}},
		{"unknown mode", statusData{}, []string{"Состояние неизвестно"}, []string{"Подключение DHCP", "Подключено:"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var out bytes.Buffer
			if err := tmpl.ExecuteTemplate(&out, "partials/wan/status", tt.data); err != nil {
				t.Fatal(err)
			}
			for _, text := range tt.want {
				if !strings.Contains(out.String(), text) {
					t.Errorf("expected %q in output:\n%s", text, out.String())
				}
			}
			for _, text := range tt.absent {
				if strings.Contains(out.String(), text) {
					t.Errorf("unexpected %q in output:\n%s", text, out.String())
				}
			}
		})
	}
}
