package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const version = "dev"
const instanceConfigRelativePath = ".a3/runtime-instance.json"

type runtimeInstanceConfig struct {
	SchemaVersion  int    `json:"schema_version"`
	PackagePath    string `json:"package_path"`
	WorkspaceRoot  string `json:"workspace_root"`
	ComposeFile    string `json:"compose_file"`
	ComposeProject string `json:"compose_project"`
	RuntimeService string `json:"runtime_service"`
	SoloBoardPort  string `json:"soloboard_port"`
	AgentPort      string `json:"agent_port"`
	StorageDir     string `json:"storage_dir"`
}

type commandRunner interface {
	Run(name string, args ...string) ([]byte, error)
}

type execRunner struct{}

func (execRunner) Run(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	return cmd.CombinedOutput()
}

func main() {
	os.Exit(run(os.Args[1:], execRunner{}, os.Stdout, os.Stderr))
}

func run(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "version":
		fmt.Fprintf(stdout, "a3 version=%s\n", version)
		return 0
	case "project":
		return runProject(args[1:], stdout, stderr)
	case "runtime":
		return runRuntime(args[1:], runner, stdout, stderr)
	case "agent":
		return runAgent(args[1:], runner, stdout, stderr)
	case "help", "-h", "--help":
		printUsage(stdout)
		return 0
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "usage:")
	fmt.Fprintln(w, "  a3 version")
	fmt.Fprintln(w, "  a3 project bootstrap --package DIR")
	fmt.Fprintln(w, "  a3 runtime up [--build]")
	fmt.Fprintln(w, "  a3 runtime doctor")
	fmt.Fprintln(w, "  a3 runtime run-once [--max-steps N] [--agent-attempts N]")
	fmt.Fprintln(w, "  a3 agent target")
	fmt.Fprintln(w, "  a3 agent install --target auto --output PATH [--build]")
}

func runProject(args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing project subcommand")
		printUsage(stderr)
		return 2
	}
	switch args[0] {
	case "bootstrap":
		if err := runProjectBootstrap(args[1:], stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown project subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runProjectBootstrap(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 project bootstrap", flag.ContinueOnError)
	flags.SetOutput(stderr)

	packagePath := flags.String("package", "", "project package directory")
	workspaceRoot := flags.String("workspace", ".", "workspace root where .a3/runtime-instance.json is written")
	composeProject := flags.String("compose-project", "", "docker compose project name for this runtime instance")
	composeFile := flags.String("compose-file", "", "A3 distribution compose file")
	runtimeService := flags.String("runtime-service", "a3-runtime", "docker compose runtime service name")
	soloBoardPort := flags.String("soloboard-port", "3470", "host SoloBoard port")
	agentPort := flags.String("agent-port", "7393", "host A3 agent control-plane port")
	storageDir := flags.String("storage-dir", "/var/lib/a3/portal-runtime", "runtime storage dir inside the A3 runtime container")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if strings.TrimSpace(*packagePath) == "" {
		return errors.New("--package is required")
	}

	absWorkspaceRoot, err := filepath.Abs(*workspaceRoot)
	if err != nil {
		return fmt.Errorf("resolve workspace root: %w", err)
	}
	absPackagePath, err := filepath.Abs(*packagePath)
	if err != nil {
		return fmt.Errorf("resolve package path: %w", err)
	}
	info, err := os.Stat(absPackagePath)
	if err != nil {
		return fmt.Errorf("project package not found: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("project package must be a directory: %s", absPackagePath)
	}

	projectName := strings.TrimSpace(*composeProject)
	if projectName == "" {
		projectName = defaultComposeProjectName(absPackagePath)
	}
	resolvedComposeFile := strings.TrimSpace(*composeFile)
	if resolvedComposeFile == "" {
		resolvedComposeFile = defaultComposeFile()
	}
	if absComposeFile, err := filepath.Abs(resolvedComposeFile); err == nil {
		resolvedComposeFile = absComposeFile
	}

	config := runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    absPackagePath,
		WorkspaceRoot:  absWorkspaceRoot,
		ComposeFile:    resolvedComposeFile,
		ComposeProject: projectName,
		RuntimeService: strings.TrimSpace(*runtimeService),
		SoloBoardPort:  strings.TrimSpace(*soloBoardPort),
		AgentPort:      strings.TrimSpace(*agentPort),
		StorageDir:     strings.TrimSpace(*storageDir),
	}
	if err := writeInstanceConfig(absWorkspaceRoot, config); err != nil {
		return err
	}

	fmt.Fprintf(stdout, "project_bootstrapped package=%s instance_config=%s\n", config.PackagePath, filepath.Join(absWorkspaceRoot, instanceConfigRelativePath))
	return nil
}

func runRuntime(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing runtime subcommand")
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "up":
		if err := runRuntimeUp(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "doctor":
		if err := runRuntimeDoctor(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "down":
		if err := runRuntimeDown(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "command-plan":
		if err := runRuntimeCommandPlan(args[1:], stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	case "run-once":
		if err := runRuntimeRunOnce(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown runtime subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runRuntimeUp(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 runtime up", flag.ContinueOnError)
	flags.SetOutput(stderr)
	build := flags.Bool("build", false, "build the runtime image before starting services")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	composePrefix := composeArgs(*config)
	return withComposeEnv(*config, func() error {
		if *build {
			if _, err := runExternal(runner, "docker", append(composePrefix, "build", config.RuntimeService)...); err != nil {
				return err
			}
		}
		if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", config.RuntimeService, "soloboard")...); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "runtime_up compose_project=%s package=%s\n", config.ComposeProject, config.PackagePath)
		return nil
	})
}

func runRuntimeDoctor(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 runtime doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	fmt.Fprintf(stdout, "package=%s\n", config.PackagePath)
	fmt.Fprintf(stdout, "compose_project=%s\n", config.ComposeProject)
	output, err := runExternal(runner, "docker", append(composeArgs(*config), "ps")...)
	if err != nil {
		return err
	}
	fmt.Fprint(stdout, string(output))
	return nil
}

func runRuntimeDown(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 runtime down", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	if _, err := runExternal(runner, "docker", append(composeArgs(*config), "down")...); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "runtime_down compose_project=%s\n", config.ComposeProject)
	return nil
}

func runRuntimeCommandPlan(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 runtime command-plan", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	fmt.Fprintf(stdout, "runtime_up=docker compose -p %s -f %s up -d %s soloboard\n", config.ComposeProject, config.ComposeFile, config.RuntimeService)
	fmt.Fprintf(stdout, "agent_install=a3 agent install --target auto --output ./.work/a3-agent/bin/a3-agent\n")
	fmt.Fprintf(stdout, "runtime_run_once=a3 runtime run-once\n")
	return nil
}

func runRuntimeRunOnce(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 runtime run-once", flag.ContinueOnError)
	flags.SetOutput(stderr)
	maxSteps := flags.String("max-steps", "", "maximum runtime steps for this cycle")
	agentAttempts := flags.String("agent-attempts", "", "maximum host agent attempts for this cycle")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	scriptPath := filepath.Join(effectiveConfig.PackagePath, "runtime", "run_once.sh")
	if _, err := os.Stat(scriptPath); err != nil {
		return fmt.Errorf("project runtime run_once.sh not found: %w", err)
	}

	output, err := runWithEnv(runtimeRunOnceEnv(effectiveConfig, *maxSteps, *agentAttempts), func() ([]byte, error) {
		return runExternal(runner, "bash", scriptPath)
	})
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	fmt.Fprintf(stdout, "runtime_run_once_script=%s\n", scriptPath)
	fmt.Fprint(stdout, string(output))
	if err != nil {
		return err
	}
	return nil
}

func runAgent(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing agent subcommand")
		printUsage(stderr)
		return 2
	}

	switch args[0] {
	case "target":
		target, err := detectHostTarget()
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
		fmt.Fprintln(stdout, target)
		return 0
	case "install":
		if err := runAgentInstall(args[1:], runner, stdout, stderr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown agent subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runAgentInstall(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a3 agent install", flag.ContinueOnError)
	flags.SetOutput(stderr)

	target := flags.String("target", "auto", "agent package target, or auto")
	output := flags.String("output", "", "host output path for the exported a3-agent binary")
	composeProject := flags.String("compose-project", "", "docker compose project name")
	composeFile := flags.String("compose-file", "", "docker compose file")
	runtimeService := flags.String("runtime-service", "", "docker compose runtime service name")
	runtimeOutput := flags.String("runtime-output", "/tmp/a3-agent-export", "temporary output path inside the runtime container")
	build := flags.Bool("build", false, "build the runtime image before exporting the agent")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if strings.TrimSpace(*output) == "" {
		return errors.New("--output is required")
	}

	resolvedTarget := strings.TrimSpace(*target)
	if resolvedTarget == "" || resolvedTarget == "auto" {
		detected, err := detectHostTarget()
		if err != nil {
			return err
		}
		resolvedTarget = detected
	}

	outputPath, err := filepath.Abs(*output)
	if err != nil {
		return fmt.Errorf("resolve output path: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}

	instanceConfig, _, instanceConfigErr := loadInstanceConfigFromWorkingTree()
	if instanceConfigErr != nil && strings.TrimSpace(*composeProject) == "" && strings.TrimSpace(*composeFile) == "" {
		return instanceConfigErr
	}
	config := runtimeInstanceConfig{}
	if instanceConfig != nil {
		config = *instanceConfig
	}
	config = applyAgentInstallOverrides(config, *composeProject, *composeFile, *runtimeService)

	composePrefix := composeArgs(config)
	if *build {
		if _, err := runExternal(runner, "docker", append(composePrefix, "build", config.RuntimeService)...); err != nil {
			return err
		}
	}
	var containerID string
	err = withComposeEnv(config, func() error {
		if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", "--no-deps", config.RuntimeService)...); err != nil {
			return err
		}
		containerBytes, err := runExternal(runner, "docker", append(composePrefix, "ps", "-q", config.RuntimeService)...)
		if err != nil {
			return err
		}
		containerID = strings.TrimSpace(string(containerBytes))
		if containerID == "" {
			return fmt.Errorf("runtime container not found for service %q", config.RuntimeService)
		}
		return nil
	})
	if err != nil {
		return err
	}

	if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "verify", "--target", resolvedTarget); err != nil {
		return err
	}
	if _, err := runExternal(runner, "docker", "exec", containerID, "a3", "agent", "package", "export", "--target", resolvedTarget, "--output", *runtimeOutput); err != nil {
		return err
	}
	if _, err := runExternal(runner, "docker", "cp", containerID+":"+*runtimeOutput, outputPath); err != nil {
		return err
	}
	if err := os.Chmod(outputPath, 0o755); err != nil {
		return fmt.Errorf("chmod exported agent: %w", err)
	}

	fmt.Fprintf(stdout, "agent_installed target=%s output=%s\n", resolvedTarget, outputPath)
	return nil
}

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

func detectHostTarget() (string, error) {
	var osPart string
	switch runtime.GOOS {
	case "darwin", "linux":
		osPart = runtime.GOOS
	default:
		return "", fmt.Errorf("unsupported host OS: %s", runtime.GOOS)
	}

	var archPart string
	switch runtime.GOARCH {
	case "amd64", "arm64":
		archPart = runtime.GOARCH
	default:
		return "", fmt.Errorf("unsupported host architecture: %s", runtime.GOARCH)
	}

	return osPart + "-" + archPart, nil
}

func envDefault(name string, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func defaultComposeFile() string {
	candidates := []string{}
	if executablePath, err := os.Executable(); err == nil {
		executableDir := filepath.Dir(executablePath)
		candidates = append(candidates, filepath.Join(executableDir, "..", "share", "a3", "docker", "compose", "a3-portal-soloboard.yml"))
	}
	candidates = append(candidates,
		"a3-engine/docker/compose/a3-portal-soloboard.yml",
		"docker/compose/a3-portal-soloboard.yml",
		"../docker/compose/a3-portal-soloboard.yml",
		"../share/a3/docker/compose/a3-portal-soloboard.yml",
	)
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return candidates[0]
}

func defaultRuntimeImage() string {
	if value := strings.TrimSpace(os.Getenv("A3_RUNTIME_IMAGE")); value != "" {
		return value
	}
	if executablePath, err := os.Executable(); err == nil {
		path := filepath.Join(filepath.Dir(executablePath), "..", "share", "a3", "runtime-image")
		if body, err := os.ReadFile(path); err == nil {
			return strings.TrimSpace(string(body))
		}
	}
	return ""
}

func writeInstanceConfig(workspaceRoot string, config runtimeInstanceConfig) error {
	path := filepath.Join(workspaceRoot, instanceConfigRelativePath)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create instance config directory: %w", err)
	}
	body, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return fmt.Errorf("encode instance config: %w", err)
	}
	body = append(body, '\n')
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return fmt.Errorf("write instance config: %w", err)
	}
	return nil
}

func loadInstanceConfigFromWorkingTree() (*runtimeInstanceConfig, string, error) {
	start, err := os.Getwd()
	if err != nil {
		return nil, "", fmt.Errorf("get working directory: %w", err)
	}
	configPath, err := findInstanceConfig(start)
	if err != nil {
		return nil, "", err
	}
	config, err := readInstanceConfig(configPath)
	if err != nil {
		return nil, "", err
	}
	return config, configPath, nil
}

func findInstanceConfig(start string) (string, error) {
	current, err := filepath.Abs(start)
	if err != nil {
		return "", err
	}
	for {
		candidate := filepath.Join(current, instanceConfigRelativePath)
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("A3 runtime instance config not found; run `a3 project bootstrap --package ./a3-project` first")
		}
		current = parent
	}
}

func readInstanceConfig(path string) (*runtimeInstanceConfig, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read instance config: %w", err)
	}
	var config runtimeInstanceConfig
	if err := json.Unmarshal(body, &config); err != nil {
		return nil, fmt.Errorf("parse instance config %s: %w", path, err)
	}
	if config.SchemaVersion != 1 {
		return nil, fmt.Errorf("unsupported instance config schema_version: %d", config.SchemaVersion)
	}
	return &config, nil
}

func defaultComposeProjectName(packagePath string) string {
	base := filepath.Base(packagePath)
	slug := make([]rune, 0, len(base))
	lastDash := false
	for _, r := range strings.ToLower(base) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			slug = append(slug, r)
			lastDash = false
			continue
		}
		if !lastDash {
			slug = append(slug, '-')
			lastDash = true
		}
	}
	normalized := strings.Trim(string(slug), "-")
	if normalized == "" {
		normalized = "project"
	}
	return "a3-" + normalized
}

func applyAgentInstallOverrides(config runtimeInstanceConfig, composeProject string, composeFile string, runtimeService string) runtimeInstanceConfig {
	if strings.TrimSpace(config.ComposeProject) == "" {
		config.ComposeProject = envDefault("A3_COMPOSE_PROJECT", "a3-portal-bundle")
	}
	if strings.TrimSpace(config.ComposeFile) == "" {
		config.ComposeFile = envDefault("A3_COMPOSE_FILE", defaultComposeFile())
	}
	if strings.TrimSpace(config.RuntimeService) == "" {
		config.RuntimeService = envDefault("A3_RUNTIME_SERVICE", "a3-runtime")
	}
	if strings.TrimSpace(composeProject) != "" {
		config.ComposeProject = strings.TrimSpace(composeProject)
	}
	if strings.TrimSpace(composeFile) != "" {
		config.ComposeFile = strings.TrimSpace(composeFile)
	}
	if strings.TrimSpace(runtimeService) != "" {
		config.RuntimeService = strings.TrimSpace(runtimeService)
	}
	return config
}

func composeArgs(config runtimeInstanceConfig) []string {
	config = applyAgentInstallOverrides(config, "", "", "")
	return []string{"compose", "-p", config.ComposeProject, "-f", config.ComposeFile}
}

func withComposeEnv(config runtimeInstanceConfig, fn func() error) error {
	return withEnv(composeEnv(config), fn)
}

func composeEnv(config runtimeInstanceConfig) map[string]string {
	overrides := map[string]string{}
	if strings.TrimSpace(config.SoloBoardPort) != "" {
		overrides["A3_BUNDLE_SOLOBOARD_PORT"] = config.SoloBoardPort
	}
	if strings.TrimSpace(config.AgentPort) != "" {
		overrides["A3_BUNDLE_AGENT_PORT"] = config.AgentPort
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" {
		overrides["A3_WORKSPACE_ROOT"] = config.WorkspaceRoot
		overrides["A3_HOST_WORKSPACE_ROOT"] = config.WorkspaceRoot
	}
	if runtimeImage := defaultRuntimeImage(); runtimeImage != "" {
		overrides["A3_RUNTIME_IMAGE"] = runtimeImage
	}
	return overrides
}

func runtimeRunOnceEnv(config runtimeInstanceConfig, maxSteps string, agentAttempts string) map[string]string {
	overrides := composeEnv(config)
	overrides["A3_PORTAL_BUNDLE_COMPOSE_FILE"] = config.ComposeFile
	overrides["A3_PORTAL_BUNDLE_PROJECT"] = config.ComposeProject
	if strings.TrimSpace(config.StorageDir) != "" {
		overrides["PORTAL_A3_BUNDLE_STORAGE_DIR"] = config.StorageDir
	}
	if strings.TrimSpace(config.WorkspaceRoot) != "" {
		overrides["A3_RUNTIME_RUN_ONCE_HOST_ROOT_DIR"] = config.WorkspaceRoot
		overrides["A3_RUNTIME_RUN_ONCE_HOST_ROOT"] = filepath.Join(config.WorkspaceRoot, ".work", "a3", "runtime-host-agent")
		overrides["A3_RUNTIME_RUN_ONCE_AGENT_WORKSPACE_ROOT"] = filepath.Join(config.WorkspaceRoot, ".work", "a3", "runtime-host-agent", "workspaces")
		overrides["A3_HOST_AGENT_BIN"] = filepath.Join(config.WorkspaceRoot, ".work", "a3-agent", "bin", "a3-agent")
	}
	if strings.TrimSpace(config.ComposeProject) != "" {
		overrides["A3_BRANCH_NAMESPACE"] = config.ComposeProject
	}
	if strings.TrimSpace(maxSteps) != "" {
		overrides["A3_RUNTIME_RUN_ONCE_MAX_STEPS"] = strings.TrimSpace(maxSteps)
	}
	if strings.TrimSpace(agentAttempts) != "" {
		overrides["A3_RUNTIME_RUN_ONCE_AGENT_ATTEMPTS"] = strings.TrimSpace(agentAttempts)
	}
	return overrides
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
