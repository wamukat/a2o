package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type projectPackageConfig struct {
	SchemaVersion      string
	PackageName        string
	KanbanProject      string
	KanbanBootstrap    string
	KanbanStatus       string
	LiveRef            string
	MaxSteps           string
	AgentAttempts      string
	AgentWorkspaceRoot string
	AgentRequiredBins  []string
	Repos              map[string]projectPackageRepo
}

type projectPackageRepo struct {
	Path  string
	Label string
}

func loadProjectPackageConfig(packagePath string) (projectPackageConfig, error) {
	config := projectPackageConfig{Repos: map[string]projectPackageRepo{}}
	projectFile := filepath.Join(packagePath, "project.yaml")
	legacyManifest := filepath.Join(packagePath, "manifest.yml")
	if _, err := os.Stat(legacyManifest); err == nil {
		return config, fmt.Errorf("manifest.yml is no longer supported; move runtime config into project.yaml: %s", legacyManifest)
	} else if err != nil && !os.IsNotExist(err) {
		return config, fmt.Errorf("inspect legacy manifest: %w", err)
	}
	file, err := os.Open(projectFile)
	if err != nil {
		if os.IsNotExist(err) {
			return config, fmt.Errorf("project package config not found: %s", projectFile)
		}
		return config, fmt.Errorf("read project package config: %w", err)
	}
	defer file.Close()

	section := ""
	subsection := ""
	currentRepo := ""
	currentList := ""
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		rawLine := stripProjectConfigComment(scanner.Text())
		if strings.TrimSpace(rawLine) == "" {
			continue
		}
		indent := leadingSpaces(rawLine)
		line := strings.TrimSpace(rawLine)
		if indent == 0 {
			currentRepo = ""
			currentList = ""
			subsection = ""
			key, value, hasValue := splitProjectConfigKey(line)
			if !hasValue {
				section = key
				continue
			}
			if key == "schema_version" {
				config.SchemaVersion = value
			}
			continue
		}
		switch section {
		case "package":
			if indent == 2 {
				key, value, hasValue := splitProjectConfigKey(line)
				if hasValue && key == "name" {
					config.PackageName = value
				}
			}
		case "kanban":
			if indent == 2 {
				key, value, hasValue := splitProjectConfigKey(line)
				subsection = ""
				if hasValue && key == "project" {
					config.KanbanProject = value
				} else if hasValue && key == "bootstrap" {
					config.KanbanBootstrap = value
				} else if !hasValue && key == "selection" {
					subsection = key
				}
			} else if indent == 4 && subsection == "selection" {
				key, value, hasValue := splitProjectConfigKey(line)
				if hasValue && key == "status" {
					config.KanbanStatus = value
				}
			}
		case "runtime":
			if indent == 2 {
				key, value, hasValue := splitProjectConfigKey(line)
				if !hasValue {
					continue
				}
				switch key {
				case "live_ref":
					config.LiveRef = value
				case "max_steps":
					config.MaxSteps = value
				case "agent_attempts":
					config.AgentAttempts = value
				}
			}
		case "agent":
			if indent == 2 {
				key, value, hasValue := splitProjectConfigKey(line)
				currentList = ""
				if !hasValue {
					if key == "required_bins" {
						currentList = key
					}
					continue
				}
				if key == "workspace_root" {
					config.AgentWorkspaceRoot = value
				} else if key == "required_bins" {
					config.AgentRequiredBins = parseProjectConfigList(value)
				}
			} else if indent == 4 && currentList == "required_bins" && strings.HasPrefix(line, "- ") {
				config.AgentRequiredBins = append(config.AgentRequiredBins, strings.TrimSpace(strings.TrimPrefix(line, "- ")))
			}
		case "repos":
			if indent == 2 {
				key, _, hasValue := splitProjectConfigKey(line)
				if !hasValue {
					currentRepo = key
					if _, ok := config.Repos[currentRepo]; !ok {
						config.Repos[currentRepo] = projectPackageRepo{}
					}
				}
			} else if indent == 4 && currentRepo != "" {
				key, value, hasValue := splitProjectConfigKey(line)
				if !hasValue {
					continue
				}
				repo := config.Repos[currentRepo]
				switch key {
				case "path":
					repo.Path = value
				case "label":
					repo.Label = value
				}
				config.Repos[currentRepo] = repo
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return config, fmt.Errorf("scan project package config: %w", err)
	}
	if strings.TrimSpace(config.SchemaVersion) == "" {
		return config, fmt.Errorf("project package config %s is missing schema_version", projectFile)
	}
	if config.SchemaVersion != "1" {
		return config, fmt.Errorf("project package config %s has unsupported schema_version: %s", projectFile, config.SchemaVersion)
	}
	if strings.TrimSpace(config.PackageName) == "" {
		return config, fmt.Errorf("project package config %s is missing package.name", projectFile)
	}
	if strings.TrimSpace(config.KanbanProject) == "" {
		return config, fmt.Errorf("project package config %s is missing kanban.project", projectFile)
	}
	if len(config.Repos) == 0 {
		return config, fmt.Errorf("project package config %s is missing repos", projectFile)
	}
	return config, nil
}

func stripProjectConfigComment(line string) string {
	if index := strings.Index(line, "#"); index >= 0 {
		return line[:index]
	}
	return line
}

func leadingSpaces(line string) int {
	count := 0
	for _, char := range line {
		if char != ' ' {
			return count
		}
		count++
	}
	return count
}

func splitProjectConfigKey(line string) (string, string, bool) {
	parts := strings.SplitN(line, ":", 2)
	key := strings.TrimSpace(parts[0])
	if len(parts) == 1 {
		return key, "", false
	}
	value := strings.TrimSpace(parts[1])
	if value == "" {
		return key, "", false
	}
	return key, trimProjectConfigScalar(value), true
}

func trimProjectConfigScalar(value string) string {
	value = strings.TrimSpace(value)
	value = strings.Trim(value, "\"'")
	return value
}

func parseProjectConfigList(value string) []string {
	trimmed := strings.TrimSpace(value)
	if !strings.HasPrefix(trimmed, "[") || !strings.HasSuffix(trimmed, "]") {
		return nil
	}
	inner := strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(trimmed, "["), "]"))
	if inner == "" {
		return []string{}
	}
	parts := strings.Split(inner, ",")
	values := make([]string, 0, len(parts))
	for _, part := range parts {
		value := trimProjectConfigScalar(part)
		if value != "" {
			values = append(values, value)
		}
	}
	return values
}

func sortedProjectRepoAliases(repos map[string]projectPackageRepo) []string {
	aliases := make([]string, 0, len(repos))
	for alias := range repos {
		aliases = append(aliases, alias)
	}
	sort.Strings(aliases)
	return aliases
}

func resolvePackagePath(packagePath string, relativePath string) string {
	if filepath.IsAbs(relativePath) {
		return filepath.Clean(relativePath)
	}
	return filepath.Clean(filepath.Join(packagePath, relativePath))
}

func workspaceContainerPath(hostWorkspaceRoot string, hostPath string) string {
	relative, err := filepath.Rel(hostWorkspaceRoot, hostPath)
	if err != nil || strings.HasPrefix(relative, "..") {
		return filepath.ToSlash(hostPath)
	}
	if relative == "." {
		return "/workspace"
	}
	return "/workspace/" + filepath.ToSlash(relative)
}
