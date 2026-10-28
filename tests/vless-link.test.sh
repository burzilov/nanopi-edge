#!/bin/bash
# Тест: разбор ссылок vless:// из 3x-ui (parse_vless_link), маскировка в сводке,
# узлы из NANOPI_VLESS_LINKS, рендер flow/fingerprint (+ sing-box check, если есть).
# Запуск: bash tests/vless-link.test.sh  (root и плата не нужны; нужен jq)
# Все UUID/ключи — фиктивные.
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

UUID=0c1a2b3c-0000-4000-8000-00000000abcd
PBK=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0
BASE="vless://${UUID}@203.0.113.10:25098"

ok_link() { # name link jq-expr
  local out
  if out=$(parse_vless_link "$2" 2>"$WORK/err") && [[ $(jq -r "$3" <<<"$out") == "true" ]]; then
    pass "$1"
  else
    fail "$1"; cat "$WORK/err"; echo "$out"
  fi
}
bad_link() { # name link grep-pattern-ошибки
  local out
  if out=$(parse_vless_link "$2" 2>"$WORK/err"); then
    fail "$1 (принята)"; echo "$out"
  elif grep -qE "$3" "$WORK/err"; then
    if grep -qF "$UUID" "$WORK/err" || grep -qF "$PBK" "$WORK/err"; then
      fail "$1 (секрет в тексте ошибки)"
    else
      pass "$1"
    fi
  else
    fail "$1 (не та ошибка)"; cat "$WORK/err"
  fi
}

# --- нормальная Reality-ссылка из 3x-ui
L1="${BASE}?type=tcp&security=reality&pbk=${PBK}&fp=chrome&sni=www.example.com&sid=0123abcd&spx=%2F&flow=xtls-rprx-vision#Finland"
ok_link "3x-ui reality: все поля" "$L1" \
  ".server==\"203.0.113.10\" and .server_port==25098 and .uuid==\"$UUID\" and .public_key==\"$PBK\"
   and .server_name==\"www.example.com\" and .short_id==\"0123abcd\" and .flow==\"xtls-rprx-vision\"
   and .fingerprint==\"chrome\" and .remark==\"Finland\" and .name==\"finland\" and .ignored==[\"spx\"]"
ok_link "пробелы/CR вокруг ссылки" "  ${L1}"$'\r'"  " '.server_port==25098'
ok_link "схема в верхнем регистре, UUID → нижний регистр" \
  "VLESS://0C1A2B3C-0000-4000-8000-00000000ABCD@203.0.113.10:443?security=reality&pbk=${PBK}&sni=a.example&sid=ab" \
  ".uuid==\"$UUID\" and .server_port==443"

# --- пустые/отсутствующие необязательные параметры → значения по умолчанию
ok_link "пустые fp/flow/type, без порта и remark" \
  "vless://${UUID}@vps.example.net?type=&security=reality&pbk=${PBK}&fp=&sni=www.example.com&sid=ab&flow=&spx=" \
  '.server=="vps.example.net" and .server_port==443 and .flow=="" and .fingerprint=="chrome" and .remark=="" and .name==""'
ok_link "type=raw, encryption=none, headerType=none, лишний /" \
  "${BASE}/?type=raw&encryption=none&headerType=none&security=reality&pbk=${PBK}&sni=www.example.com&sid=ab" \
  '.server_port==25098'
ok_link "неизвестный fp → chrome с пометкой" \
  "${BASE}?security=reality&pbk=${PBK}&sni=www.example.com&sid=ab&fp=unknownfp" \
  '.fingerprint=="chrome" and (.ignored | index("fp=unknownfp → chrome") != null)'
ok_link "fp=firefox из ссылки" \
  "${BASE}?security=reality&pbk=${PBK}&sni=www.example.com&sid=ab&fp=firefox" '.fingerprint=="firefox"'

# --- URL-кодирование, спецсимволы в remark
ok_link "remark: кириллица, пробелы, emoji, & и кавычки" \
  "${L1%%#*}#%D0%93%D0%B5%D1%80%D0%BC%D0%B0%D0%BD%D0%B8%D1%8F%20%F0%9F%87%A9%F0%9F%87%AA%20a%26b%22%27%24(x)" \
  '.remark=="Германия 🇩🇪 a&b\"'"'"'$(x)" and .name=="a-b-x"'
ok_link "remark: «reality-Ivan_Germany» → имя" "${L1%%#*}#reality-Ivan_Germany" '.name=="reality-ivan_germany"'
ok_link "remark: обратный слэш не интерпретируется" "${L1%%#*}#a%5Cnb%5Cx41" '.remark=="a\\nb\\x41"'
ok_link "query: %-кодирование и + в значениях" \
  "${BASE}?security=%72eality&pbk=${PBK}&sni=www%2Eexample.com&sid=ab&spx=%2Fpath+x" \
  '.server_name=="www.example.com" and (.ignored | index("spx") != null)'
ok_link "битый % в remark → remark пустой, ссылка принята" "${L1%%#*}#bad%ZZ" '.remark=="" and .name==""'

# --- IPv6
ok_link "IPv6 в []" "vless://${UUID}@[2001:db8::1]:8443?security=reality&pbk=${PBK}&sni=www.example.com&sid=ab#v6" \
  '.server=="2001:db8::1" and .server_port==8443'
ok_link "IPv6 в [] без порта" "vless://${UUID}@[2001:db8::2]?security=reality&pbk=${PBK}&sni=www.example.com&sid=ab" \
  '.server=="2001:db8::2" and .server_port==443'
bad_link "IPv6 без []" "vless://${UUID}@2001:db8::1:443?security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'IPv6'

# --- неподдерживаемое
bad_link "type=grpc" "${BASE}?type=grpc&security=reality&pbk=${PBK}&sni=a.example&sid=ab&serviceName=x" 'type=grpc.*не поддерживается'
bad_link "type=ws" "${BASE}?type=ws&security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'type=ws'
bad_link "type=xhttp" "${BASE}?type=xhttp&security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'type=xhttp'
bad_link "headerType=http" "${BASE}?type=tcp&headerType=http&security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'headerType'
bad_link "security=tls" "${BASE}?type=tcp&security=tls&sni=a.example" 'только Reality'
bad_link "без security" "${BASE}?type=tcp&pbk=${PBK}&sni=a.example&sid=ab" 'нет security'
bad_link "encryption≠none" "${BASE}?encryption=mlkem768x25519plus&security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'encryption'
bad_link "flow=xtls-rprx-vision-udp443" "${BASE}?security=reality&pbk=${PBK}&sni=a.example&sid=ab&flow=xtls-rprx-vision-udp443" 'flow'

# --- обязательные поля
bad_link "без pbk" "${BASE}?type=tcp&security=reality&sni=a.example&sid=ab" 'нет pbk'
bad_link "pbk пустой" "${BASE}?security=reality&pbk=&sni=a.example&sid=ab" 'нет pbk'
bad_link "pbk не base64url" "${BASE}?security=reality&pbk=abc%24def&sni=a.example&sid=ab" 'pbk'
bad_link "без sni" "${BASE}?security=reality&pbk=${PBK}&sid=ab" 'нет sni'
bad_link "без sid" "${BASE}?security=reality&pbk=${PBK}&sni=a.example" 'нет sid'
bad_link "sid нечётной длины" "${BASE}?security=reality&pbk=${PBK}&sni=a.example&sid=abc" 'sid'

# --- мусор
bad_link "пусто" "" 'пустая'
bad_link "vmess://" "vmess://eyJ2IjoiMiJ9" 'vless://'
bad_link "http-ссылка" "https://example.com/sub" 'vless://'
bad_link "без @" "vless://${UUID}203.0.113.10:443" 'UUID@'
bad_link "UUID не UUID" "vless://not-a-uuid@203.0.113.10:443?security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'UUID'
bad_link "порт 0" "vless://${UUID}@203.0.113.10:0?security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'порт'
bad_link "порт 70000" "vless://${UUID}@203.0.113.10:70000?security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'порт'
bad_link "порт не число" "vless://${UUID}@203.0.113.10:44x?security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'порт'
bad_link "хост с ; и \$()" "vless://${UUID}@a;\$(id):443?security=reality&pbk=${PBK}&sni=a.example&sid=ab" 'адрес'
bad_link "sni с кавычкой" "${BASE}?security=reality&pbk=${PBK}&sni=a%22b&sid=ab" 'sni'
bad_link "битый % в параметре" "${BASE}?security=reality&pbk=${PBK}&sni=a.example&sid=a%G1" 'URL-кодирование'
bad_link "%00 в параметре" "${BASE}?security=reality&pbk=${PBK}&sni=a%00.example&sid=ab" 'URL-кодирование'
bad_link "перенос строки внутри" "${BASE}?security=reality"$'\n'"&pbk=${PBK}" 'одной строкой'
# инъекция не исполняется
rm -f "$WORK/pwned"
parse_vless_link "${L1%%#*}#\$(touch ${WORK}/pwned)%60touch%20${WORK//\//%2F}%2Fpwned%60" >/dev/null 2>&1
if [[ -e "$WORK/pwned" ]]; then fail "remark с \$() / \`\` не исполняется"; else pass "remark с \$() / \`\` не исполняется"; fi

# --- сводка: UUID/ключ замаскированы
J=$(parse_vless_link "$L1")
S=$(vless_node_summary "$J")
if [[ "$S" != *"$UUID"* && "$S" != *"$PBK"* && "$S" == *"0c1a2b3c…abcd"* && "$S" == *"203.0.113.10:25098"* && "$S" == *"www.example.com"* ]]; then
  pass "сводка: UUID и pbk замаскированы"
else
  fail "сводка"; echo "$S"
fi
J6=$(parse_vless_link "vless://${UUID}@[2001:db8::1]:8443?security=reality&pbk=${PBK}&sni=www.example.com&sid=ab")
[[ $(vless_node_summary "$J6") == *"[2001:db8::1]:8443"* ]] && pass "сводка: IPv6 в []" || fail "сводка: IPv6 в []"

# --- без вопросов: NANOPI_VLESS_LINKS / _FILE → nodes.json
echo '[]' >"$WORK/nodes.json"
NANOPI_VLESS_LINKS="${L1}
# комментарий

germany ${BASE/203.0.113.10/198.51.100.7}?security=reality&pbk=${PBK}&sni=www.example.org&sid=cd&flow=#Finland"
printf '%s\r\n' "${L1}" >"$WORK/links.txt"   # дубль remark из файла (CRLF)
NANOPI_VLESS_LINKS_FILE="$WORK/links.txt"
vless_nodes_from_links "$WORK/nodes.json" >"$WORK/nodes.log" 2>&1
unset NANOPI_VLESS_LINKS NANOPI_VLESS_LINKS_FILE
if [[ $(jq -c '[.[].tag]' "$WORK/nodes.json") == '["vless-finland","vless-germany","vless-finland-2"]' ]]; then
  pass "NANOPI_VLESS_LINKS(+_FILE): имена из remark/«имя ссылка», дубль → -2"
else
  fail "NANOPI_VLESS_LINKS"; cat "$WORK/nodes.log"; cat "$WORK/nodes.json"
fi
if grep -qF "$UUID" "$WORK/nodes.log" || grep -qF "$PBK" "$WORK/nodes.log"; then
  fail "лог узлов без секретов"
else
  pass "лог узлов без секретов"
fi
check_nodes() { [[ $(jq -r "$2" "$WORK/nodes.json") == "true" ]] && pass "$1" || fail "$1"; }
check_nodes "nodes.json: поля узла" '.[1] == {"tag":"vless-germany","server":"198.51.100.7","server_port":25098,"uuid":"'"$UUID"'","server_name":"www.example.org","public_key":"'"$PBK"'","short_id":"cd","flow":"","fingerprint":"chrome"}'

# --- мастер целиком (интерактив): ссылка → сводка → имя; мусор → ручной ввод; default
wizard() { # stdin → ответы; результат: $WORK/wiz.nodes, $WORK/wiz.default
  bash -c '
    NANOPI_INSTALL_LIB_ONLY=1 source "$0"
    build_singbox_config() { cp "$1" "$2.nodes"; echo "$3" >"$2.default"; }
    run_wizard_and_build "$1"
  ' "$ROOT/install-singbox.sh" "$WORK/wiz" >"$WORK/wiz.out" 2>&1
}
rm -f "$WORK/wiz".*
printf '%s\n' "$L1" y "" y "vless://garbage" "" 198.51.100.7 443 "$UUID" www.example.org "$PBK" cd germany n "" | wizard
if [[ $(jq -c '[.[] | [.tag, .server, .flow, .fingerprint]]' "$WORK/wiz.nodes" 2>/dev/null) == \
  '[["vless-finland","203.0.113.10","xtls-rprx-vision","chrome"],["vless-germany","198.51.100.7","xtls-rprx-vision","chrome"]]' \
  && $(cat "$WORK/wiz.default") == vless-finland ]]; then
  pass "мастер: ссылка + ручной ввод после мусора, default = первый"
else
  fail "мастер"; cat "$WORK/wiz.out"
fi
if grep -qF "$PBK" "$WORK/wiz.out" || grep -qF "$UUID" "$WORK/wiz.out"; then
  fail "мастер: в выводе нет UUID/pbk из ссылки"
else
  pass "мастер: в выводе нет UUID/pbk из ссылки"
fi
rm -f "$WORK/wiz".*
printf '%s\n' "$L1" n "${L1%%#*}#Finland" y "" y "${L1%%#*}#finland" y "" fin2 n vless-fin2 | wizard
if [[ $(jq -c '[.[].tag]' "$WORK/wiz.nodes" 2>/dev/null) == '["vless-finland","vless-fin2"]' && $(cat "$WORK/wiz.default") == vless-fin2 ]]; then
  pass "мастер: «нет» → снова ссылка; занятое имя → переспрос; выбор default"
else
  fail "мастер: повторы"; cat "$WORK/wiz.out"
fi
rm -f "$WORK/wiz".*
NANOPI_YES=1 wizard </dev/null
if [[ ! -e "$WORK/wiz.nodes" ]] && grep -q 'NANOPI_VLESS_LINKS' "$WORK/wiz.out"; then
  pass "NANOPI_YES без ссылок → понятная ошибка"
else
  fail "NANOPI_YES без ссылок"; cat "$WORK/wiz.out"
fi
rm -f "$WORK/wiz".*
NANOPI_YES=1 NANOPI_VLESS_LINKS="$L1
de ${BASE}?security=reality&pbk=${PBK}&sni=www.example.com&sid=ab" NANOPI_VLESS_DEFAULT=de wizard </dev/null
if [[ $(jq -c '[.[].tag]' "$WORK/wiz.nodes" 2>/dev/null) == '["vless-finland","vless-de"]' && $(cat "$WORK/wiz.default") == vless-de ]]; then
  pass "NANOPI_YES + NANOPI_VLESS_LINKS + NANOPI_VLESS_DEFAULT"
else
  fail "NANOPI_YES + ссылки"; cat "$WORK/wiz.out"
fi
rm -f "$WORK/wiz".*
NANOPI_YES=1 NANOPI_VLESS_LINKS="${BASE}?type=grpc&security=reality&pbk=${PBK}&sni=a.example&sid=ab" wizard </dev/null
if [[ ! -e "$WORK/wiz.nodes" ]] && grep -q 'grpc' "$WORK/wiz.out"; then
  pass "NANOPI_VLESS_LINKS с неподдерживаемой ссылкой → стоп"
else
  fail "NANOPI_VLESS_LINKS с плохой ссылкой"; cat "$WORK/wiz.out"
fi

# --- рендер: flow/fp из узлов, старые узлы без полей → как раньше
jq '. + [{"tag":"vless-old","server":"vps.example.net","server_port":443,"uuid":"00000000-0000-4000-8000-000000000009",
  "server_name":"www.example.com","public_key":"'"$PBK"'","short_id":"0123abcd"}]
  | (.[0].fingerprint = "firefox")' "$WORK/nodes.json" >"$WORK/nodes2.json"
OUT="$WORK/config.json"
if render_singbox_config "$ROOT/templates/sing-box.config.json.tpl" "$WORK/nodes2.json" testsecret vless-germany end0 >"$OUT"; then
  pass "рендер с узлами из ссылок"
else
  fail "рендер с узлами из ссылок"
fi
ob() { jq -c --arg t "$1" '.outbounds[] | select(.tag==$t)' "$OUT"; }
[[ $(ob vless-finland | jq -r '.flow + " " + .tls.utls.fingerprint') == "xtls-rprx-vision firefox" ]] \
  && pass "outbound: flow и fp из ссылки" || fail "outbound: flow и fp из ссылки"
[[ $(ob vless-germany | jq -r 'has("flow")') == "false" ]] && pass "outbound: flow= пусто → без flow" || fail "outbound: пустой flow"
[[ $(ob vless-old | jq -r '.flow + " " + .tls.utls.fingerprint') == "xtls-rprx-vision chrome" ]] \
  && pass "старый узел без flow/fp → vision/chrome" || fail "старый узел без flow/fp"
[[ $(jq -c '[.route.rules[] | select(.outbound=="direct" and .ip_cidr) | .ip_cidr][0]' "$OUT") == '["198.51.100.7/32","203.0.113.10/32"]' ]] \
  && pass "IPv4 узлов из ссылок → правило direct" || fail "IPv4 узлов → правило direct"
if command -v sing-box >/dev/null 2>&1; then
  if sing-box check -c "$OUT" >"$WORK/check.log" 2>&1; then pass "sing-box check (узлы из ссылок)"
  else fail "sing-box check"; cat "$WORK/check.log"; fi
else
  echo "skip - sing-box нет в PATH"
fi

echo
if [[ $fails -eq 0 ]]; then echo "итого: все PASS"; else echo "итого: FAIL=$fails"; exit 1; fi
