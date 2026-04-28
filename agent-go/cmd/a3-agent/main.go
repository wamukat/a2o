package main

import (
	"encoding/json"
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
	if len(args) > 0 && (args[0] == "help" || args[0] == "-h" || args[0] == "--help") {
		printAgentUsage()
		return 0
	}
	if len(args) > 0 && args[0] == "doctor" {
		return runDoctor(args[1:])
	}
	if len(args) > 0 && args[0] == "cleanup-workspace" {
		return runCleanupWorkspace(args[1:])
	}
	if len(args) > 0 && (args[0] == "worker:stdin-bundle" || args[0] == "worker-stdin-bundle") {
		return runWorkerStdinBundle(args[1:])
	}
	if len(args) > 1 && args[0] == "worker" && args[1] == "stdin-bundle" {
		return runWorkerStdinBundle(args[2:])
	}
	if err := validateRemovedA3AgentEnvironment(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	configPath := preScanConfigPath(args)
	config, err := agent.LoadRuntimeProfileConfig(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	flags := flag.NewFlagSet("a2o-agent", flag.ContinueOnError)
	flags.Usage = printAgentUsage
	configFlag := flags.String("config", configPath, "runtime profile JSON file")
	agentName := flags.String("agent", defaultString("A2O_AGENT_NAME", config.AgentName, "local-agent"), "agent name used when polling the A2O control plane")
	projectKey := flags.String("project", defaultString("A2O_AGENT_PROJECT_KEY", config.ProjectKey, envDefault("A2O_PROJECT_KEY", "")), "agent/session default project key used when claiming jobs")
	controlPlaneURL := defaultString("A2O_CONTROL_PLANE_URL", config.ControlPlaneURL, "http://127.0.0.1:7393")
	flags.StringVar(&controlPlaneURL, "control-plane-url", controlPlaneURL, "A2O control plane base URL")
	flags.StringVar(&controlPlaneURL, "engine", controlPlaneURL, "alias for --control-plane-url")
	controlPlaneConnectTimeout := flags.Duration("control-plane-connect-timeout", envDuration("A2O_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT", durationFromConfig(config.ControlPlaneConnectTimeout)), "TCP connect timeout for the A2O control plane")
	controlPlaneRequestTimeout := flags.Duration("control-plane-request-timeout", envDuration("A2O_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT", durationFromConfig(config.ControlPlaneRequestTimeout)), "per-request timeout for the A2O control plane")
	controlPlaneRetryCount := flags.Int("control-plane-retries", envInt("A2O_AGENT_CONTROL_PLANE_RETRIES", config.ControlPlaneRetryCount), "retry count for transient control plane request failures")
	controlPlaneRetryDelay := flags.Duration("control-plane-retry-delay", envDuration("A2O_AGENT_CONTROL_PLANE_RETRY_DELAY", durationFromConfig(config.ControlPlaneRetryDelay)), "delay between transient control plane retries")
	agentToken := flags.String("agent-token", envDefault("A2O_AGENT_TOKEN", ""), "bearer token for the A2O control plane")
	agentTokenFile := flags.String("agent-token-file", defaultString("A2O_AGENT_TOKEN_FILE", config.AgentTokenFile, ""), "file containing bearer token for the A2O control plane")
	workspaceRoot := flags.String("workspace-root", defaultString("A2O_AGENT_WORKSPACE_ROOT", config.WorkspaceRoot, ""), "agent-owned workspace root for materialized jobs")
	loop := flags.Bool("loop", false, "run continuously until interrupted")
	pollInterval := flags.Duration("poll-interval", envDuration("A2O_AGENT_POLL_INTERVAL", time.Second), "idle poll interval for loop mode")
	maxIterations := flags.Int("max-iterations", envInt("A2O_AGENT_MAX_ITERATIONS", 0), "maximum loop iterations; 0 means unlimited")
	sourceAliases := sourceAliasFlag(mergeSourceAliases(config.SourceAliases, parseSourceAliases(envDefault("A2O_AGENT_SOURCE_ALIASES", ""))))
	flags.Var(&sourceAliases, "source-alias", "source alias mapping for materialized jobs, in name=path form; repeatable")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	_ = configFlag

	client := agent.HTTPClient{
		BaseURL:        controlPlaneURL,
		ProjectKey:     *projectKey,
		Token:          *agentToken,
		TokenFile:      *agentTokenFile,
		FallbackToken:  config.AgentToken,
		ConnectTimeout: *controlPlaneConnectTimeout,
		RequestTimeout: *controlPlaneRequestTimeout,
		RetryCount:     *controlPlaneRetryCount,
		RetryDelay:     *controlPlaneRetryDelay,
	}
	worker := agent.Worker{
		AgentName:         *agentName,
		Client:            client,
		HeartbeatErrorLog: os.Stderr,
		EventLog:          os.Stdout,
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

func printAgentUsage() {
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  a2o-agent [--loop] [--control-plane-url URL]")
	fmt.Fprintln(os.Stderr, "  a2o-agent doctor --workspace-root PATH --source-path NAME=PATH")
	fmt.Fprintln(os.Stderr, "  a2o-agent cleanup-workspace --workspace-root PATH --descriptor PATH [--dry-run]")
	fmt.Fprintln(os.Stderr, "  a2o-agent worker stdin-bundle")
}

func runDoctor(args []string) int {
	if err := validateRemovedA3AgentEnvironment(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	configPath := preScanConfigPath(args)
	config, err := agent.LoadRuntimeProfileConfig(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	flags := flag.NewFlagSet("a2o-agent doctor", flag.ContinueOnError)
	flags.Usage = printAgentUsage
	configFlag := flags.String("config", configPath, "runtime profile JSON file")
	agentName := flags.String("agent", defaultString("A2O_AGENT_NAME", config.AgentName, "local-agent"), "agent name")
	controlPlaneURL := defaultString("A2O_CONTROL_PLANE_URL", config.ControlPlaneURL, "http://127.0.0.1:7393")
	flags.StringVar(&controlPlaneURL, "control-plane-url", controlPlaneURL, "A2O control plane base URL")
	flags.StringVar(&controlPlaneURL, "engine", controlPlaneURL, "alias for --control-plane-url")
	workspaceRoot := flags.String("workspace-root", defaultString("A2O_AGENT_WORKSPACE_ROOT", config.WorkspaceRoot, ""), "agent-owned workspace root for materialized jobs")
	sourceAliases := sourceAliasFlag(mergeSourceAliases(config.SourceAliases, parseSourceAliases(envDefault("A2O_AGENT_SOURCE_ALIASES", ""))))
	flags.Var(&sourceAliases, "source-path", "source alias mapping for materialized jobs, in name=path form; repeatable")
	flags.Var(&sourceAliases, "source-alias", "compatibility alias for --source-path")
	requiredBins := stringSliceFlag(config.RequiredBins)
	flags.Var(&requiredBins, "required-bin", "required executable visible to the agent runtime; repeatable")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	_ = configFlag
	config.AgentName = *agentName
	config.ControlPlaneURL = controlPlaneURL
	config.WorkspaceRoot = *workspaceRoot
	config.SourceAliases = map[string]string(sourceAliases)
	config.RequiredBins = []string(requiredBins)
	if err := doctorConfig(config); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Printf("agent_doctor=ok profile=%s control_plane_url=%s workspace_root=%s source_aliases=%s\n",
		defaultIfEmpty(config.AgentName, "local-agent"),
		defaultIfEmpty(config.ControlPlaneURL, "http://127.0.0.1:7393"),
		config.WorkspaceRoot,
		sourceAliases.String(),
	)
	return 0
}

func durationFromConfig(raw string) time.Duration {
	if strings.TrimSpace(raw) == "" {
		return 0
	}
	value, err := time.ParseDuration(strings.TrimSpace(raw))
	if err != nil {
		return 0
	}
	return value
}

func runCleanupWorkspace(args []string) int {
	if err := validateRemovedA3AgentEnvironment(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	configPath := preScanConfigPath(args)
	config, err := agent.LoadRuntimeProfileConfig(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	flags := flag.NewFlagSet("a2o-agent cleanup-workspace", flag.ContinueOnError)
	flags.Usage = printAgentUsage
	configFlag := flags.String("config", configPath, "runtime profile JSON file")
	workspaceRoot := flags.String("workspace-root", defaultString("A2O_AGENT_WORKSPACE_ROOT", config.WorkspaceRoot, ""), "agent-owned workspace root")
	descriptorPath := flags.String("descriptor", "", "workspace descriptor JSON file")
	dryRun := flags.Bool("dry-run", false, "report cleanup candidates without deleting")
	if err := flags.Parse(args); err != nil {
		return 2
	}
	_ = configFlag
	if flags.NArg() != 0 {
		fmt.Fprintf(os.Stderr, "unexpected arguments: %s\n", strings.Join(flags.Args(), " "))
		return 2
	}
	if strings.TrimSpace(*workspaceRoot) == "" {
		fmt.Fprintln(os.Stderr, "--workspace-root is required")
		return 1
	}
	if strings.TrimSpace(*descriptorPath) == "" {
		fmt.Fprintln(os.Stderr, "--descriptor is required")
		return 1
	}
	descriptor, err := readWorkspaceDescriptor(*descriptorPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	result, err := (agent.WorkspaceMaterializer{WorkspaceRoot: *workspaceRoot}).CleanupDescriptor(descriptor, *dryRun)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Printf("agent_workspace_cleanup=completed dry_run=%t workspace_root=%s worktrees=%d removed_workspace=%t\n",
		result.DryRun,
		result.WorkspaceRoot,
		len(result.RemovedWorktrees),
		result.RemovedWorkspace,
	)
	for _, worktree := range result.RemovedWorktrees {
		fmt.Printf("removed_worktree=%s\n", worktree)
	}
	return 0
}

func readWorkspaceDescriptor(path string) (agent.WorkspaceDescriptor, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return agent.WorkspaceDescriptor{}, fmt.Errorf("read workspace descriptor: %w", err)
	}
	var descriptor agent.WorkspaceDescriptor
	if err := json.Unmarshal(content, &descriptor); err != nil {
		return agent.WorkspaceDescriptor{}, fmt.Errorf("parse workspace descriptor: %w", err)
	}
	return descriptor, nil
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
	for _, requiredBin := range config.RequiredBins {
		requiredBin = strings.TrimSpace(requiredBin)
		if requiredBin == "" {
			continue
		}
		if _, err := exec.LookPath(requiredBin); err != nil {
			return fmt.Errorf("required bin %s is not available: %w", requiredBin, err)
		}
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
	probePath := filepath.Join(config.WorkspaceRoot, ".a2o-agent-write-probe")
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

type stringSliceFlag []string

func (f *stringSliceFlag) String() string {
	if f == nil {
		return ""
	}
	return strings.Join(*f, ",")
}

func (f *stringSliceFlag) Set(value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return fmt.Errorf("value must not be empty")
	}
	*f = append(*f, value)
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
	return envDefault("A2O_AGENT_CONFIG", "")
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

func removedA3AgentInputError(removed string, replacement string) error {
	return fmt.Errorf("removed A3 compatibility input: %s; migration_required=true replacement=%s", removed, replacement)
}

func validateRemovedA3AgentEnvironment() error {
	replacements := map[string]string{
		"A3_AGENT_CONFIG":                        "A2O_AGENT_CONFIG",
		"A3_AGENT_NAME":                          "A2O_AGENT_NAME",
		"A3_CONTROL_PLANE_URL":                   "A2O_CONTROL_PLANE_URL",
		"A3_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT": "A2O_AGENT_CONTROL_PLANE_CONNECT_TIMEOUT",
		"A3_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT": "A2O_AGENT_CONTROL_PLANE_REQUEST_TIMEOUT",
		"A3_AGENT_CONTROL_PLANE_RETRIES":         "A2O_AGENT_CONTROL_PLANE_RETRIES",
		"A3_AGENT_CONTROL_PLANE_RETRY_DELAY":     "A2O_AGENT_CONTROL_PLANE_RETRY_DELAY",
		"A3_AGENT_TOKEN":                         "A2O_AGENT_TOKEN",
		"A3_AGENT_TOKEN_FILE":                    "A2O_AGENT_TOKEN_FILE",
		"A3_AGENT_WORKSPACE_ROOT":                "A2O_AGENT_WORKSPACE_ROOT",
		"A3_AGENT_POLL_INTERVAL":                 "A2O_AGENT_POLL_INTERVAL",
		"A3_AGENT_MAX_ITERATIONS":                "A2O_AGENT_MAX_ITERATIONS",
		"A3_AGENT_SOURCE_ALIASES":                "A2O_AGENT_SOURCE_ALIASES",
	}
	for removed, replacement := range replacements {
		if strings.TrimSpace(os.Getenv(removed)) != "" {
			return removedA3AgentInputError("environment variable "+removed, "environment variable "+replacement)
		}
	}
	return nil
}
