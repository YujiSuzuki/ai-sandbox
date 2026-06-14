// update-check - Check for AI Sandbox template updates
//
// Reads the update check state file and template configuration to show
// whether a newer version of the template is available.
//
// Usage:
//   go run .sandbox/tools/update-check.go [options]
//   -state <path>   State file path (default: .sandbox/.state/update-check)
//   -config <path>  Template config path (default: .sandbox/config/template-source.conf)
//   -json           JSON output
//
// Examples:
//   go run .sandbox/tools/update-check.go
//   go run .sandbox/tools/update-check.go -json
//
// ---
//
// AI Sandbox テンプレートの更新チェックツール。
// 更新チェック状態ファイルとテンプレート設定を読み取り、
// 新しいバージョンが利用可能かどうかを表示します。
//
// 使い方:
//   go run .sandbox/tools/update-check.go
//   go run .sandbox/tools/update-check.go -json
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type templateConfig struct {
	Repo          string `json:"repo"`
	Channel       string `json:"channel"`
	Enabled       bool   `json:"enabled"`
	IntervalHours int    `json:"interval_hours"`
}

type updateStatus struct {
	LatestVersion string `json:"latest_version"`
	Repo          string `json:"repo"`
	Channel       string `json:"channel"`
	ReleaseURL    string `json:"release_url"`
	Enabled       bool   `json:"enabled"`
}

func main() {
	stateFile := flag.String("state", ".sandbox/.state/update-check", "State file path")
	configFile := flag.String("config", ".sandbox/config/template-source.conf", "Template config path")
	jsonOutput := flag.Bool("json", false, "JSON output")
	flag.Parse()

	cfg, err := parseTemplateConfig(*configFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading config: %v\n", err)
		os.Exit(1)
	}

	version := readStateVersion(*stateFile)

	status := updateStatus{
		LatestVersion: version,
		Repo:          cfg.Repo,
		Channel:       cfg.Channel,
		ReleaseURL:    fmt.Sprintf("https://github.com/%s/releases", cfg.Repo),
		Enabled:       cfg.Enabled,
	}

	if *jsonOutput {
		data, _ := json.MarshalIndent(status, "", "  ")
		fmt.Println(string(data))
		return
	}

	fmt.Println("📦 Template Update Status")
	fmt.Println()
	if status.LatestVersion != "" {
		fmt.Printf("Latest version: %s\n", status.LatestVersion)
	} else {
		fmt.Println("Latest version: (not yet checked)")
	}
	fmt.Printf("Repository: %s\n", status.Repo)
	fmt.Printf("Channel: %s\n", status.Channel)
	fmt.Printf("Updates enabled: %v\n", status.Enabled)
	fmt.Printf("\nRelease notes: %s\n", status.ReleaseURL)
	if status.LatestVersion != "" {
		fmt.Println("\n💡 To update, ask: \"Please update to the latest version\"")
	}
}

func readStateVersion(stateFile string) string {
	data, err := os.ReadFile(stateFile)
	if err != nil {
		return ""
	}

	content := strings.TrimSpace(string(data))
	if content == "" {
		return ""
	}

	parts := strings.SplitN(content, ":", 2)
	if len(parts) != 2 {
		return ""
	}

	return parts[1]
}

func parseTemplateConfig(configFile string) (*templateConfig, error) {
	file, err := os.Open(configFile)
	if err != nil {
		return nil, fmt.Errorf("failed to open config file: %w", err)
	}
	defer file.Close()

	cfg := &templateConfig{
		Channel:       "all",
		Enabled:       true,
		IntervalHours: 24,
	}

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		value = strings.Trim(value, `"'`)

		switch key {
		case "TEMPLATE_REPO":
			cfg.Repo = value
		case "CHECK_CHANNEL":
			cfg.Channel = value
		case "CHECK_UPDATES":
			cfg.Enabled = (value == "true")
		case "CHECK_INTERVAL_HOURS":
			hours, err := strconv.Atoi(value)
			if err == nil {
				cfg.IntervalHours = hours
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error reading config file: %w", err)
	}

	if cfg.Repo == "" {
		return nil, fmt.Errorf("TEMPLATE_REPO is required in config file")
	}

	return cfg, nil
}
