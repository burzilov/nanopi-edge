package web

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"nanopi-webui/internal/hairpin"
	"nanopi-webui/internal/mobilevless"
	"nanopi-webui/internal/portfwd"
)

// portRuleView — строка таблицы «Проброс портов».
type portRuleView struct {
	portfwd.Rule
	Hint     string // предупреждение: адрес вне сети NanoPi
	HintWarn bool
	HasStats bool   // счётчики прочитаны из nft
	Conns    uint64 // новых подключений (первые пакеты через DNAT)
	Bytes    uint64 // трафик соединений в обе стороны
}

// ConnsLabel / TrafficLabel — колонка «Подключений / трафик».
func (v portRuleView) ConnsLabel() string   { return strconv.FormatUint(v.Conns, 10) }
func (v portRuleView) TrafficLabel() string { return humanBytes(v.Bytes) }

func humanBytes(n uint64) string {
	const unit = 1024
	if n < unit {
		return strconv.FormatUint(n, 10) + " Б"
	}
	units := []string{"КБ", "МБ", "ГБ", "ТБ", "ПБ"}
	f := float64(n) / unit
	i := 0
	for f >= unit && i < len(units)-1 {
		f /= unit
		i++
	}
	if f < 10 {
		return strconv.FormatFloat(f, 'f', 1, 64) + " " + units[i]
	}
	return strconv.FormatFloat(f, 'f', 0, 64) + " " + units[i]
}

type rateLimitView struct {
	portfwd.RateLimit
	Default   bool   // в файле нет настроек — действуют значения по умолчанию
	Drops     uint64 // отброшено новых подключений
	HasDrops  bool
	PerMinStr string // значения формы (при ошибке — как ввёл пользователь)
	BurstStr  string
}

// hairpinView — блок «DNS hairpin» (HAIRPIN_DNS_TARGET в .env).
type hairpinView struct {
	Target   string   // сохранённый адрес подмены
	Input    string   // значение поля (при ошибке — как ввёл пользователь)
	Active   bool     // alias записан в конфиг dnsmasq
	WanIPs   []string // белые IP, которые подменяются
	ConfPath string
	Err      string // статус не прочитан
	// Исключения «имя → адрес» (hairpin-overrides.json).
	Overrides     []hairpin.OverrideState
	OverridesPath string
	MaxOverrides  int
	OvName        string // форма добавления (при ошибке — как ввёл пользователь)
	OvIP          string
}

// portRuleForm — значения формы как ввёл пользователь (для повторного показа при ошибке).
type portRuleForm struct {
	ID       string
	Proto    string
	WanPort  string
	DestIP   string
	DestPort string
	Comment  string
}

type portFwdPageData struct {
	Rules     []portRuleView
	RateLimit rateLimitView
	StatsErr  string // счётчики не прочитаны (нет nft/прав, таблица не загружена)
	LanCIDR   string
	WanIPs    []string
	Hairpin   hairpinView
	EditID    string
	Form      portRuleForm // форма добавления
	Edit      portRuleForm // форма редактирования (EditID)
	Message   string
	Error     string
}

func (s *Server) portFwdData(msg, errMsg string) portFwdPageData {
	d := portFwdPageData{
		Message: msg,
		Error:   errMsg,
		Rules:   []portRuleView{},
		Form:    portRuleForm{Proto: "tcp"},
		LanCIDR: portfwd.LanCIDR(),
		WanIPs:  hairpin.WanIPv4s(),
	}
	d.Hairpin = hairpinData(d.WanIPs)
	st, err := portfwd.Load()
	if err != nil {
		if d.Error == "" {
			d.Error = err.Error()
		}
		return d
	}
	rl := st.Limit()
	d.RateLimit = rateLimitView{
		RateLimit: rl, Default: st.RateLimit == nil,
		PerMinStr: strconv.Itoa(rl.PerMinute), BurstStr: strconv.Itoa(rl.Burst),
	}
	counters, cerr := readCounters()
	if cerr != nil {
		d.StatsErr = "Счётчики недоступны: " + cerr.Error()
	}
	if c, ok := counters[portfwd.DropCounter]; ok {
		d.RateLimit.Drops, d.RateLimit.HasDrops = c.Packets, true
	}
	for _, r := range st.Rules {
		hint, warn := portfwd.DestHint(d.LanCIDR, r.DestIP)
		v := portRuleView{Rule: r, Hint: hint, HintWarn: warn}
		cn, cb := portfwd.CounterNames(r.ID)
		if c, ok := counters[cn]; ok {
			v.HasStats, v.Conns = true, c.Packets
		}
		if c, ok := counters[cb]; ok {
			v.HasStats, v.Bytes = true, c.Bytes
		}
		d.Rules = append(d.Rules, v)
	}
	return d
}

// hairpinStatus / applyHairpin — подменяются в тестах.
var (
	hairpinStatus      = hairpin.GetStatus
	applyHairpin       = hairpin.Apply
	addHairpinOverride = hairpin.AddOverride
	delHairpinOverride = hairpin.DeleteOverride
)

func hairpinData(wan []string) hairpinView {
	v := hairpinView{
		WanIPs: wan, ConfPath: hairpin.ConfPath(),
		OverridesPath: hairpin.OverridesPath(), MaxOverrides: hairpin.MaxOverrides,
	}
	st, err := hairpinStatus()
	if err != nil {
		v.Err = "Не удалось прочитать " + hairpin.EnvKey + ": " + err.Error()
		return v
	}
	v.Target, v.Input, v.Active = st.Target, st.Target, st.Active
	v.Overrides = st.Overrides
	if len(st.WanIPs) > 0 {
		v.WanIPs = st.WanIPs
	}
	return v
}

func ruleToForm(r portfwd.Rule) portRuleForm {
	return portRuleForm{
		ID: r.ID, Proto: r.Proto, WanPort: strconv.Itoa(r.WanPort),
		DestIP: r.DestIP, DestPort: strconv.Itoa(r.DestPort), Comment: r.Comment,
	}
}

func formFromRequest(r *http.Request) portRuleForm {
	return portRuleForm{
		ID:       strings.TrimSpace(r.FormValue("id")),
		Proto:    strings.ToLower(strings.TrimSpace(r.FormValue("proto"))),
		WanPort:  strings.TrimSpace(r.FormValue("wan_port")),
		DestIP:   strings.TrimSpace(r.FormValue("dest_ip")),
		DestPort: strings.TrimSpace(r.FormValue("dest_port")),
		Comment:  strings.TrimSpace(r.FormValue("comment")),
	}
}

// parseRuleForm превращает форму в правило. Пустой внутренний порт = внешний.
func parseRuleForm(f portRuleForm) (portfwd.Rule, error) {
	if f.Proto == "" {
		f.Proto = "tcp"
	}
	wan, err := strconv.Atoi(f.WanPort)
	if err != nil || wan < 1 || wan > 65535 {
		return portfwd.Rule{}, fmt.Errorf("внешний порт: нужно число от 1 до 65535")
	}
	dest := wan
	if f.DestPort != "" {
		dest, err = strconv.Atoi(f.DestPort)
		if err != nil || dest < 1 || dest > 65535 {
			return portfwd.Rule{}, fmt.Errorf("внутренний порт: нужно число от 1 до 65535 (или пусто — как внешний)")
		}
	}
	if f.DestIP == "" {
		return portfwd.Rule{}, fmt.Errorf("укажите внутренний IP, например 10.10.10.179")
	}
	r := portfwd.Rule{
		ID: f.ID, Proto: f.Proto, WanPort: wan, DestIP: f.DestIP, DestPort: dest, Comment: f.Comment,
	}
	if err := checkReservedPort(r); err != nil {
		return portfwd.Rule{}, err
	}
	return r, nil
}

// readCounters — nft-счётчики таблицы проброса (подменяется в тестах).
var readCounters = portfwd.Counters

// reservedPorts — порты, которые NanoPi сам слушает на WAN (DNAT их перехватит).
var reservedPorts = func() map[int]string {
	out := map[int]string{}
	if st, err := mobilevless.Load(); err == nil && st.Enabled && st.Port > 0 {
		out[st.Port] = "мобильный VLESS"
	}
	return out
}

func checkReservedPort(r portfwd.Rule) error {
	name, ok := reservedPorts()[r.WanPort]
	if !ok {
		return nil
	}
	for _, p := range r.Protos() {
		if p == "tcp" {
			return fmt.Errorf("внешний порт TCP %d занят: на нём NanoPi принимает %s", r.WanPort, name)
		}
	}
	return nil
}

func (s *Server) handlePortFwdPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "port_forwards", s.portFwdData("", ""))
}

// handlePortFwdInner — перерисовать блок (например, открыть/закрыть редактирование).
func (s *Server) handlePortFwdInner(w http.ResponseWriter, r *http.Request) {
	d := s.portFwdData("", "")
	if id := strings.TrimSpace(r.URL.Query().Get("edit")); id != "" {
		for _, rv := range d.Rules {
			if rv.ID == id {
				d.EditID = id
				d.Edit = ruleToForm(rv.Rule)
				break
			}
		}
		if d.EditID == "" {
			d.Error = "Правило не найдено — обновите страницу"
		}
	}
	s.render(w, "port_forwards_inner", d)
}

func (s *Server) handlePortFwdAdd(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	f := formFromRequest(r)
	f.ID = ""
	rule, err := parseRuleForm(f)
	if err == nil {
		_, err = portfwd.Add(rule)
	}
	if err != nil {
		d := s.portFwdData("", err.Error())
		d.Form = f
		s.render(w, "port_forwards_inner", d)
		return
	}
	s.render(w, "port_forwards_inner", s.portFwdData("Правило добавлено и применено", ""))
}

func (s *Server) handlePortFwdUpdate(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	f := formFromRequest(r)
	rule, err := parseRuleForm(f)
	if err == nil {
		_, err = portfwd.Update(rule)
	}
	if err != nil {
		d := s.portFwdData("", err.Error())
		d.EditID = f.ID
		d.Edit = f
		s.render(w, "port_forwards_inner", d)
		return
	}
	s.render(w, "port_forwards_inner", s.portFwdData("Правило изменено и применено", ""))
}

func (s *Server) handlePortFwdToggle(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	id := strings.TrimSpace(r.FormValue("id"))
	enable := r.FormValue("enabled") == "1"
	if enable {
		if st, err := portfwd.Load(); err == nil {
			for _, rr := range st.Rules {
				if rr.ID == id {
					if err := checkReservedPort(rr); err != nil {
						s.render(w, "port_forwards_inner", s.portFwdData("", err.Error()))
						return
					}
				}
			}
		}
	}
	if _, err := portfwd.SetEnabled(id, enable); err != nil {
		s.render(w, "port_forwards_inner", s.portFwdData("", err.Error()))
		return
	}
	msg := "Правило выключено"
	if enable {
		msg = "Правило включено"
	}
	s.render(w, "port_forwards_inner", s.portFwdData(msg, ""))
}

func (s *Server) handlePortFwdDelete(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	if _, err := portfwd.Delete(r.FormValue("id")); err != nil {
		s.render(w, "port_forwards_inner", s.portFwdData("", err.Error()))
		return
	}
	s.render(w, "port_forwards_inner", s.portFwdData("Правило удалено", ""))
}

func (s *Server) handlePortFwdRateLimit(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	perMinStr := strings.TrimSpace(r.FormValue("per_minute"))
	burstStr := strings.TrimSpace(r.FormValue("burst"))
	rl := portfwd.RateLimit{
		Enabled: r.FormValue("enabled") == "1",
		Log:     r.FormValue("log") == "1",
	}
	fail := func(msg string) {
		d := s.portFwdData("", msg)
		d.RateLimit.RateLimit = rl
		d.RateLimit.PerMinStr, d.RateLimit.BurstStr = perMinStr, burstStr
		s.render(w, "port_forwards_inner", d)
	}
	var err error
	if rl.PerMinute, err = strconv.Atoi(perMinStr); err != nil {
		fail("порог: нужно целое число новых подключений в минуту")
		return
	}
	if rl.Burst, err = strconv.Atoi(burstStr); err != nil {
		fail("всплеск (burst): нужно целое число подключений")
		return
	}
	if _, err := portfwd.SetRateLimit(rl); err != nil {
		fail(err.Error())
		return
	}
	msg := "Ограничение частоты выключено"
	if rl.Enabled {
		msg = fmt.Sprintf("Ограничение применено: не больше %d новых подключений в минуту с одного IP (всплеск до %d)", rl.PerMinute, rl.Burst)
	}
	s.render(w, "port_forwards_inner", s.portFwdData(msg, ""))
}

// handlePortFwdHairpin сохраняет HAIRPIN_DNS_TARGET в .env и применяет его
// (hairpin-dns-refresh: alias в dnsmasq + перезапуск dnsmasq). Пусто или
// кнопка «Отключить» — подмена выключается.
func (s *Server) handlePortFwdHairpin(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	input := strings.TrimSpace(r.FormValue("target"))
	if r.FormValue("disable") == "1" {
		input = ""
	}
	target, err := hairpin.NormalizeTarget(input)
	if err == nil {
		err = applyHairpin(target)
		if err != nil {
			err = fmt.Errorf("DNS hairpin: %w", err)
		}
	}
	if err != nil {
		d := s.portFwdData("", err.Error())
		d.Hairpin.Input = input
		s.render(w, "port_forwards_inner", d)
		return
	}
	msg := "Подмена DNS выключена"
	if target != "" {
		msg = "Подмена DNS применена: из дома белый IP ведёт на " + target
	}
	s.render(w, "port_forwards_inner", s.portFwdData(msg, ""))
}

// handlePortFwdHairpinOverrideAdd — исключение «имя → адрес» из общей подмены.
func (s *Server) handlePortFwdHairpinOverrideAdd(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	name := strings.TrimSpace(r.FormValue("name"))
	ip := strings.TrimSpace(r.FormValue("ip"))
	o, err := addHairpinOverride(name, ip)
	if err != nil {
		d := s.portFwdData("", "Исключение DNS: "+err.Error())
		d.Hairpin.OvName, d.Hairpin.OvIP = name, ip
		s.render(w, "port_forwards_inner", d)
		return
	}
	s.render(w, "port_forwards_inner", s.portFwdData("Исключение применено: из дома "+o.Name+" (и поддомены) ведёт на "+o.IP, ""))
}

func (s *Server) handlePortFwdHairpinOverrideDelete(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	name := strings.TrimSpace(r.FormValue("name"))
	if err := delHairpinOverride(name); err != nil {
		s.render(w, "port_forwards_inner", s.portFwdData("", "Исключение DNS: "+err.Error()))
		return
	}
	s.render(w, "port_forwards_inner", s.portFwdData("Исключение "+name+" удалено", ""))
}

// portFwdAPI — JSON для /api/port-forwards: правила + действующее ограничение + счётчики.
type portFwdAPI struct {
	portfwd.Store
	Limit    portfwd.RateLimit          `json:"effective_rate_limit"`
	Counters map[string]portfwd.Counter `json:"counters,omitempty"`
	Hairpin  *hairpin.Status            `json:"hairpin,omitempty"`
}

func (s *Server) handleAPIPortFwdGet(w http.ResponseWriter, r *http.Request) {
	st, err := portfwd.Load()
	if err != nil {
		s.writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	c, _ := readCounters()
	resp := portFwdAPI{Store: st, Limit: st.Limit(), Counters: c}
	if hs, err := hairpinStatus(); err == nil {
		resp.Hairpin = &hs
	}
	s.writeJSON(w, http.StatusOK, resp)
}
