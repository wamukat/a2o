package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/wamukat/a3-engine/agent-go/internal/agent"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) > 0 && args[0] == "doctor" {
		return runDoctor(args[1:])
	}

	configPath := preScanConfigPath(args)
	config, err := agent.LoadRuntimeProfileConfig(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	flags := flag.NewFlagSet("a3-agent", flag.ContinueOnError)
	configFlag := flags.String("config", configPath, "runtime profile JSON file")
	agentName := flags.String("agent", defaultString("A3_AGENT_NAME", config.AgentName, "local-agent"), "agent name used when polling the A3 control plane")
	controlPlaneURL := flags.String("control-plane-url", defaultString("A3_CONTROL_PLANE_URL", config.ControlPlaneURL, "http://127.0.0.1:7393"), "A3 control plane base URL")
	agentToken := flags.String("agent-token", os.Getenv("A3_AGENT_TOKEN"), "bearer token for the A3 control plane")
	agentTokenFile := flags.String("agent-token-file", defaultString("A3_AGENT_TOKEN_FILE", config.AgentTokenFile, ""), "file containing bearer token for the A3 control plane")
	workspaceRoot := flags.String("workspace-root", defaultString("A3_AGENT_WORKSPACE_ROOT", config.WorkspaceRoot, ""), "agent-owned workspace root for materialized jobs")
	loop := flags.Bool("loop", false, "run continuously until interrupted")
	pollInterval := flags.Duration("poll-interval", envDuration("A3_AGENT_POLL_INTERVAL", time.Second), "idle poll interval for loop mode")
	maxIterations := flags.Int("max-iterations", envInt("A3_AGENT_MAX_ITERATIONS", 0), "maximum loop iterations; 0 means unlimited")
	sourceAliases := sourceAliasFlag(mergeSourceAliases(config.SourceAliases, parseSourceAliases(os.Getenv("A3_AGENT_SOURCE_ALIASES"))))
	flags.Var(&sourceAliases, "source-alias", "source alias mapping for materialized jobs, in name=path form; repeatable")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	_ = configFlag

	client := agent.HTTPClient{
		BaseURL:       *controlPlaneURL,
		Token:         *agentToken,
		TokenFile:     *agentTokenFile,
		FallbackToken: config.AgentToken,
	}
	worker := agent.Worker{
		AgentName: *agentName,
		Client:    client,
	}
	if *workspaceRoot != "" || len(sourceAliases) > 0 {
		worker.Materializer = agent.WorkspaceMaterializer{
			WorkspaceRoot: *workspaceRoot,
			SourceAliases: map[string]string(sourceAliases),
		}
	}
	if *loop {
		result, err := worker.RunLoop(agent.LoopOptions{
			PollInterval:  *pollInterval,
			MaxIterations: *maxIterations,
		})
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		fmt.Printf("agent loop completed iterations=%d jobs=%d idle=%d\n", result.Iterations, result.Jobs, result.Idle)
		return 0
	}
	result, idle, err := worker.RunOnce()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if idle {
		fmt.Println("agent idle")
		return 0
	}
	fmt.Printf("agent completed %s status=%s\n", result.JobID, result.Status)
	return 0
}

func runDoctor(args []string) int {
	configPath := preScanConfigPath(args)
	config, err := agent.LoadRuntimeProfileConfig(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	flags := flag.NewFlagSet("a3-agent doctor", flag.ContinueOnError)
	configFlag := flags.String("config", configPath, "runtime profile JSON file")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	if *configFlag == "" {
		fmt.Fprintln(os.Stderr, "runtime profile config is required")
		return 1
	}
	if err := doctorConfig(config); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	sourceAliases := sourceAliasFlag(config.SourceAliases)
	fmt.Printf("agent_doctor=ok profile=%s control_plane_url=%s workspace_root=%s source_aliases=%s\n",
		defaultIfEmpty(config.AgentName, "local-agent"),
		defaultIfEmpty(config.ControlPlaneURL, "http://127.0.0.1:7393"),
		config.WorkspaceRoot,
		sourceAliases.String(),
	)
	return 0
}

func resolveAgentToken(directToken, tokenFile, fallbackToken string) (string, error) {
	if directToken != "" {
		return directToken, nil
	}
	if tokenFile != "" {
		content, err := os.ReadFile(tokenFile)
		if err != nil {
			return "", fmt.Errorf("read agent token file: %w", err)
		}
		token := strings.TrimSpace(string(content))
		if token == "" {
			return "", fmt.Errorf("agent token file is empty: %s", tokenFile)
		}
		return token, nil
	}
	return fallbackToken, nil
}

func doctorConfig(config agent.RuntimeProfileConfig) error {
	if config.WorkspaceRoot == "" {
		return fmt.Errorf("workspace_root is required")
	}
	if len(config.SourceAliases) == 0 {
		return fmt.Errorf("source_aliases are required")
	}
	for alias, path := range config.SourceAliases {
		if alias == "" || path == "" {
			return fmt.Errorf("source_aliases must be name=path")
		}
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("source alias %s is not accessible: %w", alias, err)
		}
		if !info.IsDir() {
			return fmt.Errorf("source alias %s must point to a directory", alias)
		}
		if err := gitCheck(path, "rev-parse", "--is-inside-work-tree"); err != nil {
			return fmt.Errorf("source alias %s is not a git worktree: %w", alias, err)
		}
		if out, err := gitOutput(path, "status", "--porcelain", "--untracked-files=all"); err != nil {
			return fmt.Errorf("source alias %s git status failed: %w", alias, err)
		} else if strings.TrimSpace(out) != "" {
			return fmt.Errorf("source alias %s is dirty", alias)
		}
	}
	if err := os.MkdirAll(config.WorkspaceRoot, 0o755); err != nil {
		return fmt.Errorf("workspace_root is not writable: %w", err)
	}
	probePath := filepath.Join(config.WorkspaceRoot, ".a3-agent-write-probe")
	if err := os.WriteFile(probePath, []byte("ok\n"), 0o600); err != nil {
		return fmt.Errorf("workspace_root is not writable: %w", err)
	}
	_ = os.Remove(probePath)
	return nil
}

func gitCheck(root string, args ...string) error {
	_, err := gitOutput(root, args...)
	return err
}

func gitOutput(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("git %v failed: %w: %s", args, err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

type sourceAliasFlag map[string]string

func (f *sourceAliasFlag) String() string {
	if f == nil {
		return ""
	}
	pairs := make([]string, 0, len(*f))
	for key, value := range *f {
		pairs = append(pairs, key+"="+value)
	}
	return strings.Join(pairs, ",")
}

func (f *sourceAliasFlag) Set(value string) error {
	key, path, ok := strings.Cut(value, "=")
	if !ok || key == "" || path == "" {
		return fmt.Errorf("source alias must be name=path")
	}
	if *f == nil {
		*f = sourceAliasFlag{}
	}
	(*f)[key] = path
	return nil
}

func parseSourceAliases(value string) map[string]string {
	aliases := map[string]string{}
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		key, path, ok := strings.Cut(item, "=")
		if ok && key != "" && path != "" {
			aliases[key] = path
		}
	}
	return aliases
}

func preScanConfigPath(args []string) string {
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if arg == "-config" || arg == "--config" {
			if index+1 < len(args) {
				return args[index+1]
			}
			return ""
		}
		for _, prefix := range []string{"-config=", "--config="} {
			if strings.HasPrefix(arg, prefix) {
				return strings.TrimPrefix(arg, prefix)
			}
		}
	}
	return envDefault("A3_AGENT_CONFIG", "")
}

func mergeSourceAliases(base map[string]string, overlays ...map[string]string) map[string]string {
	merged := map[string]string{}
	for key, value := range base {
		merged[key] = value
	}
	for _, overlay := range overlays {
		for key, value := range overlay {
			merged[key] = value
		}
	}
	return merged
}

func defaultString(envKey string, configValue string, fallback string) string {
	if value := os.Getenv(envKey); value != "" {
		return value
	}
	if configValue != "" {
		return configValue
	}
	return fallback
}

func defaultIfEmpty(value string, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func envDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envInt(key string, fallback int) int {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}
