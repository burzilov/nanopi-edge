package domains

import (
	"encoding/json"
	"fmt"
)

// ExtractProxyDomains читает domain_suffix из первого route.rules
// с outbound=="proxy" и полем domain_suffix.
func ExtractProxyDomains(configJSON []byte) ([]string, error) {
	var root map[string]any
	if err := json.Unmarshal(configJSON, &root); err != nil {
		return nil, err
	}
	route, ok := root["route"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("нет route в config")
	}
	rules, ok := route["rules"].([]any)
	if !ok {
		return nil, fmt.Errorf("нет route.rules")
	}
	for _, raw := range rules {
		rule, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if rule["outbound"] != "proxy" {
			continue
		}
		ds, has := rule["domain_suffix"]
		if !has {
			continue
		}
		arr, ok := ds.([]any)
		if !ok {
			return nil, fmt.Errorf("domain_suffix не массив")
		}
		out := make([]string, 0, len(arr))
		for _, v := range arr {
			s, ok := v.(string)
			if !ok {
				continue
			}
			out = append(out, s)
		}
		return out, nil
	}
	return nil, fmt.Errorf("не найдено правило proxy+domain_suffix")
}

// MergeProxyDomains находит route rule с outbound "proxy" и domain_suffix,
// заменяет domain_suffix на list. Тот же список пишется в DNS-правило
// (dns.rules: server "dns-proxy" + domain_suffix), если оно есть, — чтобы домены
// из списка и резолвились через прокси. Старые конфиги без такого правила не меняются.
// Пустой список отклоняется: правило без условий в sing-box совпадает со всем.
func MergeProxyDomains(configJSON []byte, list []string) ([]byte, error) {
	if len(list) == 0 {
		return nil, fmt.Errorf("список доменов пуст")
	}
	var root map[string]any
	if err := json.Unmarshal(configJSON, &root); err != nil {
		return nil, err
	}
	route, ok := root["route"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("нет route в config")
	}
	rules, ok := route["rules"].([]any)
	if !ok {
		return nil, fmt.Errorf("нет route.rules")
	}
	found := false
	for i, raw := range rules {
		rule, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if rule["outbound"] != "proxy" {
			continue
		}
		if _, has := rule["domain_suffix"]; !has {
			continue
		}
		arr := make([]any, len(list))
		for j, d := range list {
			arr[j] = d
		}
		rule["domain_suffix"] = arr
		rules[i] = rule
		found = true
		break
	}
	if !found {
		return nil, fmt.Errorf("не найдено правило proxy+domain_suffix")
	}
	route["rules"] = rules
	root["route"] = route
	syncDNSProxyDomains(root, list)
	return json.MarshalIndent(root, "", "  ")
}

// syncDNSProxyDomains обновляет domain_suffix во всех dns.rules с server "dns-proxy"
// и полем domain_suffix. Нет dns/rules/правила — ничего не делает.
func syncDNSProxyDomains(root map[string]any, list []string) {
	dns, ok := root["dns"].(map[string]any)
	if !ok {
		return
	}
	rules, ok := dns["rules"].([]any)
	if !ok {
		return
	}
	for i, raw := range rules {
		rule, ok := raw.(map[string]any)
		if !ok || rule["server"] != "dns-proxy" {
			continue
		}
		if _, has := rule["domain_suffix"]; !has {
			continue
		}
		arr := make([]any, len(list))
		for j, d := range list {
			arr[j] = d
		}
		rule["domain_suffix"] = arr
		rules[i] = rule
	}
	dns["rules"] = rules
	root["dns"] = dns
}
