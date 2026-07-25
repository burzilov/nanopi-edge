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
// заменяет domain_suffix на list.
func MergeProxyDomains(configJSON []byte, list []string) ([]byte, error) {
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
	return json.MarshalIndent(root, "", "  ")
}
