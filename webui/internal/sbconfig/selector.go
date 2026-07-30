package sbconfig

import (
	"encoding/json"
	"fmt"
	"os"
)

// SetSelectorDefault ставит default у outbound type=selector с tag=group.
func SetSelectorDefault(configPath, group, outbound string) error {
	b, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	var root map[string]any
	if err := json.Unmarshal(b, &root); err != nil {
		return fmt.Errorf("config.json: %w", err)
	}
	outs, ok := root["outbounds"].([]any)
	if !ok {
		return fmt.Errorf("нет outbounds")
	}
	found := false
	for i, raw := range outs {
		ob, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if ob["type"] != "selector" || ob["tag"] != group {
			continue
		}
		ob["default"] = outbound
		outs[i] = ob
		found = true
		break
	}
	if !found {
		return fmt.Errorf("selector %q не найден", group)
	}
	root["outbounds"] = outs
	out, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return err
	}
	out = append(out, '\n')
	tmp := configPath + ".tmp"
	if err := os.WriteFile(tmp, out, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, configPath)
}
