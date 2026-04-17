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
	command := strings.TrimSpace(name + " " + strings.Join(args, " "))
	message := strings.TrimSpace(string(output))
	if message == "" {
		return nil, fmt.Errorf("%s failed: %w", command, err)
	}
	return nil, fmt.Errorf("%s failed: %w\n%s", command, err, message)
}

func envDefault(name string, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
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
	publicAgentPath := filepath.Join(hostRootDir, ".work", "a2o-agent", "bin", "a2o-agent")
	if _, err := os.Stat(publicAgentPath); err == nil {
		return publicAgentPath
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" && config.WorkspaceRoot != hostRootDir {
		publicWorkspaceAgentPath := filepath.Join(config.WorkspaceRoot, ".work", "a2o-agent", "bin", "a2o-agent")
		if _, err := os.Stat(publicWorkspaceAgentPath); err == nil {
			return publicWorkspaceAgentPath
		}
	}
	return filepath.Join(hostRootDir, ".work", "a3-agent", "bin", "a3-agent")
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
