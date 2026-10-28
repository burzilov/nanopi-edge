#!/bin/bash
# Тест: рендер templates/sing-box.config.json.tpl через render_singbox_config (install-singbox.sh),
# DNS-схема (dns-proxy/dns-direct, синхронизация доменов), правило IP узлов, lan.conf, upgrade.
# Запуск: bash tests/singbox-render.test.sh  (root и плата не нужны; нужен jq;
#   если в PATH есть sing-box — дополнительно sing-box check)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

NANOPI_INSTALL_LIB_ONLY=1
# shellcheck disable=SC1091
source "$ROOT/install-singbox.sh"
set +e

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
check() { # name jq-expr (должен вернуть true)
  if [[ $(jq -r "$2" "$OUT") == "true" ]]; then pass "$1"; else fail "$1"; fi
}

TPL="$ROOT/templates/sing-box.config.json.tpl"
# Тестовые узлы: IPv4 (TEST-NET), дубль IPv4 и hostname. Секреты — фиктивные.
cat >"$WORK/nodes.json" <<'JSON'
[
 {"tag":"vless-a","server":"203.0.113.10","server_port":443,"uuid":"00000000-0000-4000-8000-000000000001",
  "server_name":"www.example.com","public_key":"jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0","short_id":"0123abcd"},
 {"tag":"vless-b","server":"203.0.113.10","server_port":8443,"uuid":"00000000-0000-4000-8000-000000000002",
  "server_name":"www.example.com","public_key":"jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0","short_id":"0123abcd"},
 {"tag":"vless-c","server":"vps.example.net","server_port":443,"uuid":"00000000-0000-4000-8000-000000000003",
  "server_name":"www.example.com","public_key":"jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0","short_id":"0123abcd"}
]
JSON

OUT="$WORK/config.json"
if render_singbox_config "$TPL" "$WORK/nodes.json" testsecret vless-a end0 >"$OUT" && jq -e . "$OUT" >/dev/null; then
  pass "рендер → валидный JSON"
else
  fail "рендер"; echo "итого: FAIL"; exit 1
fi

# --- плейсхолдеры и outbounds
if grep -q '@[A-Z_]*@' "$OUT"; then fail "остались плейсхолдеры"; else pass "плейсхолдеры подставлены"; fi
check "outbounds: direct + 3 vless + selector" '[.outbounds[].type] == ["direct","vless","vless","vless","selector"]'
check "selector proxy default" '(.outbounds[] | select(.tag=="proxy") | .default) == "vless-a"'

# --- IP узлов: только отдельное правило direct, сразу после ip_is_private
check "reject 169.254/16 без /32 узлов" '(.route.rules[] | select(.action=="reject" and .ip_cidr) | .ip_cidr) == ["169.254.0.0/16"]'
check "VPS /32 ровно в одном правиле" '[.route.rules[] | select((.ip_cidr // []) | index("203.0.113.10/32"))] | length == 1'
check "VPS-правило: direct, без дублей" '[.route.rules[] | select((.ip_cidr // []) | index("203.0.113.10/32"))][0] == {"action":"route","outbound":"direct","ip_cidr":["203.0.113.10/32"]}'
check "VPS-правило сразу после ip_is_private" '(.route.rules | map(.ip_is_private == true) | index(true)) as $i | .route.rules[$i+1].ip_cidr == ["203.0.113.10/32"]'
check "VPS /32 нет в правиле DNS-IP" '(.route.rules[] | select((.ip_cidr // []) | index("94.140.14.14/32")) | .ip_cidr | index("203.0.113.10/32")) == null'
check "hostname-узел не попал в ip_cidr" '[.route.rules[] | .ip_cidr // [] | .[] | select(test("example"))] | length == 0'

# --- DNS-схема
check "dns.servers = dns-proxy, dns-direct" '[.dns.servers[].tag] == ["dns-proxy","dns-direct"]'
check "dns-proxy: AdGuard DoH по IP+SNI через proxy" '(.dns.servers[] | select(.tag=="dns-proxy")) as $s | $s.type=="https" and $s.server=="94.140.14.14" and $s.path=="/dns-query" and $s.tls.server_name=="dns.adguard-dns.com" and $s.detour=="proxy"'
check "dns-direct: тот же AdGuard без detour" '(.dns.servers[] | select(.tag=="dns-direct")) as $s | $s.server=="94.140.14.14" and $s.tls.server_name=="dns.adguard-dns.com" and ($s | has("detour") | not)'
check "dns.final = dns-direct" '.dns.final == "dns-direct"'
check "route.default_domain_resolver = dns-direct" '.route.default_domain_resolver == "dns-direct"'
check "домены прокси: DNS == route (один источник)" '([.route.rules[] | select(.outbound=="proxy" and .domain_suffix)][0].domain_suffix) == ([.dns.rules[] | select(.server=="dns-proxy" and .domain_suffix)][0].domain_suffix)'
check "ipify.org в списке прокси" '[.route.rules[] | select(.outbound=="proxy" and .domain_suffix)][0].domain_suffix | index("ipify.org") != null'
check "DNS geosite → dns-proxy" '[.dns.rules[] | select(.server=="dns-proxy") | .rule_set // [] | .[]] == ["geosite-category-ai-!cn","geosite-ru-blocked","geosite-telegram"]'
check "DNS без geoip" '[.dns.rules[] | .rule_set // [] | .[] | select(startswith("geoip"))] | length == 0'
check ".ru/.su/.рф (+punycode) → dns-direct" '[.dns.rules[] | select(.server=="dns-direct" and .domain_suffix)][0].domain_suffix == [".ru",".su",".рф",".xn--p1ai"]'
check "фолбэк: evaluate dns-proxy → respond → dns-direct" '(.dns.rules | map(.action)) [-4:] == ["evaluate","respond","respond","route"] and .dns.rules[-1].server == "dns-direct"'

# --- inbounds / DNS-IP / отсутствие личных правил
check "нет inbound dns-in и порта 5353" '[.inbounds[] | select(.tag=="dns-in" or .listen_port==5353)] | length == 0'
check "нет правила inbound dns-in" '[.route.rules[] | select(.inbound)] | length == 0'
check "port 53 → hijack-dns" '[.route.rules[] | select(.port==53 and .action=="hijack-dns")] | length == 1'
check "DNS-IP (DoH клиентов LAN) → proxy" '(.route.rules[] | select((.ip_cidr // []) | index("94.140.14.14/32")) | .outbound) == "proxy"'
if grep -Eq '8\.210\.2\.99|176\.235\.29\.|144\.31\.119\.213' "$TPL"; then fail "личные IP в шаблоне"; else pass "личных IP Ивана в шаблоне нет"; fi

# --- без IPv4-узлов отдельное VPS-правило не создаётся
jq '[.[] | select(.tag=="vless-c")]' "$WORK/nodes.json" >"$WORK/nodes-host.json"
OUT2="$WORK/config-host.json"
render_singbox_config "$TPL" "$WORK/nodes-host.json" testsecret vless-c end0 >"$OUT2"
if [[ $(jq '[.route.rules[] | select(.outbound=="direct" and .ip_cidr)] | length' "$OUT2") == 0 ]] \
  && [[ $(jq '.route.rules | length' "$OUT2") == $(( $(jq '.route.rules | length' "$OUT") - 1 )) ]]; then
  pass "только hostname-узлы → без VPS-правила"
else
  fail "только hostname-узлы → без VPS-правила"
fi

# --- sing-box check (если бинарь доступен)
if command -v sing-box >/dev/null 2>&1; then
  if sing-box check -c "$OUT" >"$WORK/check.log" 2>&1; then pass "sing-box check ($(sing-box version | head -1))"
  else fail "sing-box check"; cat "$WORK/check.log"; fi
else
  echo "skip - sing-box нет в PATH"
fi

# --- lan.conf (свежая установка: router-on → nanopi_write_dnsmasq_lan)
NANOPI_TEMPLATE_DIR="$ROOT/templates"
# shellcheck disable=SC1091
source "$ROOT/scripts/common.sh"
set +e
nanopi_render_template dnsmasq-lan.conf.tpl "$WORK/lan.conf" LAN=enp1s0 WAN=end0
if grep -qx 'server=94.140.14.14' "$WORK/lan.conf" && grep -qx 'server=94.140.15.15' "$WORK/lan.conf" \
  && ! grep -q '5353' "$WORK/lan.conf" && ! grep -q '@' "$WORK/lan.conf" \
  && grep -qx 'interface=enp1s0' "$WORK/lan.conf" && grep -qx 'except-interface=end0' "$WORK/lan.conf"; then
  pass "lan.conf: server=94.140.14.14/15.15, без :5353"
else
  fail "lan.conf"; cat "$WORK/lan.conf"
fi
# Requires=, не Wants=: ExecStartPost sing-box синхронно делает try-restart dnsmasq,
# а dnsmasq After=sing-box — с Wants= запуск взаимно блокируется (сеть без DNS/DHCP).
if grep -qx 'Requires=sing-box.service' "$ROOT/templates/dnsmasq-sing-box.conf" \
  && grep -qx 'After=sing-box.service' "$ROOT/templates/dnsmasq-sing-box.conf" \
  && ! grep -q '^Wants=' "$ROOT/templates/dnsmasq-sing-box.conf"; then
  pass "dnsmasq drop-in: After+Requires sing-box (без Wants)"
else
  fail "dnsmasq drop-in"
fi

# --- upgrade: config.json по умолчанию не трогается; lan.conf инсталлятор не пишет
SB_CFG="$WORK/live-config.json"
echo '{"live":true}' >"$SB_CFG"
before=$(sha256sum "$SB_CFG")
INSTALL_MODE=upgrade SINGBOX_BIN=true
yesno() { return 1; }                 # пользователь жмёт Enter (по умолчанию n)
run_wizard_and_build() { echo "WIZARD CALLED"; }
explain() { :; }; info() { :; }
if [[ $(maybe_rebuild_config secret) != *"WIZARD CALLED"* ]] && [[ $(sha256sum "$SB_CFG") == "$before" ]]; then
  pass "upgrade: config.json не пересобирается по умолчанию"
else
  fail "upgrade: config.json изменён/мастер вызван"
fi
if grep -nE 'nanopi_write_dnsmasq_lan|dnsmasq\.d/lan\.conf' "$ROOT/install-singbox.sh" "$ROOT/install-webui.sh" >/dev/null; then
  fail "инсталлятор пишет lan.conf"
else
  pass "upgrade: инсталлятор lan.conf не пишет (только router-on)"
fi

echo
if [[ $fails -eq 0 ]]; then echo "итого: все PASS"; else echo "итого: FAIL=$fails"; exit 1; fi
