package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func runExternal(runner commandRunner, name string, args ...string) ([]byte, error) {
	output, err := runner.Run(name, args...)
	if err == nil {
		return output, nil
	}
	command := sanitizePublicCommand(strings.TrimSpace(name + " " + strings.Join(args, " ")))
	message := sanitizePublicCommand(strings.TrimSpace(string(output)))
	if message == "" {
		return nil, fmt.Errorf("%s failed: %w", command, err)
	}
	return nil, fmt.Errorf("%s failed: %w\n%s", command, err, message)
}

func sanitizePublicCommand(command string) string {
	replacer := strings.NewReplacer(
		"a3-runtime", "<runtime-service>",
		"/var/lib/a3", "<runtime-storage>",
		"/tmp/a3-engine", "<runtime-preset-dir>",
		"/opt/a3", "<runtime-tools>",
		"/tmp/a3-runtime", "/tmp/a2o-runtime",
		".a3", "<agent-metadata>",
		"A3_", "A2O_INTERNAL_",
		"'a3'", "'<engine-entrypoint>'",
		"\"a3\"", "\"<engine-entrypoint>\"",
		" a3 ", " <engine-entrypoint> ",
	)
	return replacer.Replace(command)
}

func printUserFacingError(w interface{ Write([]byte) (int, error) }, err error) {
	fmt.Fprintln(w, err)
	category, remediation := classifyUserFacingError(err.Error())
	fmt.Fprintf(w, "error_category=%s\n", category)
	fmt.Fprintf(w, "remediation=%s\n", remediation)
}

func classifyUserFacingError(message string) (string, string) {
	text := strings.ToLower(message)
	switch {
	case strings.Contains(text, "project.yaml"), strings.Contains(text, "schema"), strings.Contains(text, "config"), strings.Contains(text, "executor"), strings.Contains(text, "manifest"):
		return "configuration_error", "Review project.yaml and package settings, then rerun the A2O command."
	case strings.Contains(text, "dirty"), strings.Contains(text, "has changes"), strings.Contains(text, "changed files"), strings.Contains(text, "working tree"):
		return "workspace_dirty", "Clean, commit, or stash the reported repo files before rerunning A2O."
	case strings.Contains(text, "merge conflict"), strings.Contains(text, "unmerged"), strings.Contains(text, "conflict marker"):
		return "merge_conflict", "Resolve the merge conflict or update the base branch before rerunning A2O."
	case strings.Contains(text, "verification"):
		return "verification_failed", "Inspect verification output and fix product tests, lint, or dependencies."
	case strings.Contains(text, "docker"):
		return "runtime_failed", "Check Docker runtime status, compose project settings, and the printed command output."
	default:
		return "runtime_failed", "Inspect the error above, fix the reported cause, and rerun the A2O command."
	}
}

func envDefault(name string, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func envDefaultCompat(publicName string, legacyName string, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(publicName)); value != "" {
		return value
	}
	return envDefault(legacyName, fallback)
}

func envDefaultValue(value string, fallback string) string {
	if strings.TrimSpace(value) != "" {
		return strings.TrimSpace(value)
	}
	return fallback
}

func parsePositiveInt(value string, label string) (int, error) {
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return 0, fmt.Errorf("parse %s: %w", label, err)
	}
	if parsed <= 0 {
		return 0, fmt.Errorf("%s must be > 0", label)
	}
	return parsed, nil
}

func resolveDefaultHostAgentBin(config runtimeInstanceConfig, hostRootDir string) string {
	publicAgentPath := filepath.Join(hostRootDir, hostAgentBinRelativePath)
	if _, err := os.Stat(publicAgentPath); err == nil {
		return publicAgentPath
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" && config.WorkspaceRoot != hostRootDir {
		publicWorkspaceAgentPath := filepath.Join(config.WorkspaceRoot, hostAgentBinRelativePath)
		if _, err := os.Stat(publicWorkspaceAgentPath); err == nil {
			return publicWorkspaceAgentPath
		}
	}
	return publicAgentPath
}

func agentInstallCommand(outputPath string) string {
	return "a2o agent install --target auto --output " + shellQuote(outputPath)
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func shellJoin(args []string) string {
	quoted := make([]string, 0, len(args))
	for _, arg := range args {
		quoted = append(quoted, shellQuote(arg))
	}
	return strings.Join(quoted, " ")
}

func nonEmptyLines(output []byte) []string {
	lines := strings.Split(string(output), "\n")
	values := make([]string, 0, len(lines))
	for _, line := range lines {
		value := strings.TrimSpace(line)
		if value != "" {
			values = append(values, value)
		}
	}
	return values
}

func appendFile(path string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer file.Close()
	_, err = file.Write(body)
	return err
}

func runWithEnv(overrides map[string]string, fn func() ([]byte, error)) ([]byte, error) {
	var output []byte
	err := withEnv(overrides, func() error {
		var runErr error
		output, runErr = fn()
		return runErr
	})
	return output, err
}

func withEnv(overrides map[string]string, fn func() error) error {
	originals := make(map[string]*string, len(overrides))
	for key, value := range overrides {
		if current, ok := os.LookupEnv(key); ok {
			copyValue := current
			originals[key] = &copyValue
		} else {
			originals[key] = nil
		}
		if err := os.Setenv(key, value); err != nil {
			return err
		}
	}
	defer func() {
		for key, value := range originals {
			if value == nil {
				_ = os.Unsetenv(key)
			} else {
				_ = os.Setenv(key, *value)
			}
		}
	}()
	return fn()
}
