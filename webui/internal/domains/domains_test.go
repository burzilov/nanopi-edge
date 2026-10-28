package domains

import (
	"encoding/json"
	"reflect"
	"testing"
)

const cfgWithDNS = `{
  "dns": {"rules": [
    {"domain_suffix": ["old.example"], "action": "route", "server": "dns-proxy"},
    {"rule_set": ["geosite-ru-blocked"], "action": "route", "server": "dns-proxy"},
    {"domain_suffix": [".ru"], "action": "route", "server": "dns-direct"}
  ]},
  "route": {"rules": [
    {"action": "route", "outbound": "proxy", "ip_cidr": ["94.140.14.14/32"]},
    {"action": "route", "outbound": "proxy", "domain_suffix": ["old.example"]},
    {"action": "route", "outbound": "direct", "domain_suffix": [".ru"]}
  ]}
}`

func suffixes(t *testing.T, rule any) []string {
	t.Helper()
	m := rule.(map[string]any)
	arr, _ := m["domain_suffix"].([]any)
	out := []string{}
	for _, v := range arr {
		out = append(out, v.(string))
	}
	return out
}

func TestMergeProxyDomainsSyncsDNSRule(t *testing.T) {
	list := []string{"2ip.io", "ipify.org"}
	out, err := MergeProxyDomains([]byte(cfgWithDNS), list)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := json.Unmarshal(out, &root); err != nil {
		t.Fatal(err)
	}
	route := root["route"].(map[string]any)["rules"].([]any)
	dns := root["dns"].(map[string]any)["rules"].([]any)
	if got := suffixes(t, route[1]); !reflect.DeepEqual(got, list) {
		t.Fatalf("route proxy domain_suffix = %v", got)
	}
	if got := suffixes(t, dns[0]); !reflect.DeepEqual(got, list) {
		t.Fatalf("dns-proxy domain_suffix = %v", got)
	}
	if got := suffixes(t, dns[2]); !reflect.DeepEqual(got, []string{".ru"}) {
		t.Fatalf("dns-direct domain_suffix изменён: %v", got)
	}
	if got := suffixes(t, route[2]); !reflect.DeepEqual(got, []string{".ru"}) {
		t.Fatalf("route direct domain_suffix изменён: %v", got)
	}
	got, err := ExtractProxyDomains(out)
	if err != nil || !reflect.DeepEqual(got, list) {
		t.Fatalf("Extract = %v, %v", got, err)
	}
}

func TestMergeProxyDomainsWithoutDNSRule(t *testing.T) {
	cfg := `{"dns":{"servers":[]},"route":{"rules":[{"action":"route","outbound":"proxy","domain_suffix":["a.example"]}]}}`
	out, err := MergeProxyDomains([]byte(cfg), []string{"b.example"})
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	_ = json.Unmarshal(out, &root)
	if _, has := root["dns"].(map[string]any)["rules"]; has {
		t.Fatal("dns.rules не должно появляться в старом конфиге")
	}
}

func TestMergeProxyDomainsRejectsEmpty(t *testing.T) {
	if _, err := MergeProxyDomains([]byte(cfgWithDNS), nil); err == nil {
		t.Fatal("ожидалась ошибка для пустого списка")
	}
}
