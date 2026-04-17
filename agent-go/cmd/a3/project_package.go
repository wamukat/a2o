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
	Project            string
	KanbanProject      string
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
	file, err := os.Open(projectFile)
	if err != nil {
		if os.IsNotExist(err) {
			return config, nil
		}
		return config, fmt.Errorf("read project package config: %w", err)
	}
	defer file.Close()

	section := ""
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
			key, value, hasValue := splitProjectConfigKey(line)
			if !hasValue {
				section = key
				continue
			}
			if key == "project" {
				config.Project = value
			}
			continue
		}
		switch section {
		case "kanban":
			if indent == 2 {
				key, value, hasValue := splitProjectConfigKey(line)
				if hasValue && key == "project" {
					config.KanbanProject = value
				}
			}
		case "runtime":
			if indent == 2 {
				key, value, hasValue := splitProjectConfigKey(line)
				if !hasValue {
					continue
				}
				switch key {
				case "kanban_status":
					config.KanbanStatus = value
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
