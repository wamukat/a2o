package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

const (
	kanbanModeBundled  = "bundled"
	kanbanModeExternal = "external"
)

func runKanban(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing kanban subcommand")
		printUsage(stderr)
		return 2
	}
	if isHelpArg(args[0]) {
		printUsage(stdout)
		return 0
	}

	switch args[0] {
	case "up":
		if err := runKanbanUp(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "doctor":
		if err := runKanbanDoctor(args[1:], runner, stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "url":
		if err := runKanbanURL(args[1:], stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown kanban subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runKanbanUp(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o kanban up", flag.ContinueOnError)
	flags.SetOutput(stderr)
	build := flags.Bool("build", false, "build the runtime image before starting services")
	freshBoard := flags.Bool("fresh-board", false, "fail if the configured Kanbalone data volume already exists")
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
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	composePrefix := composeArgs(effectiveConfig)
	return withComposeEnv(effectiveConfig, func() error {
		if isExternalKanban(effectiveConfig) {
			if err := checkExternalKanbanHealth(kanbanPublicURL(effectiveConfig)); err != nil {
				return err
			}
			if *build {
				if _, err := runExternal(runner, "docker", append(composePrefix, "build", effectiveConfig.RuntimeService)...); err != nil {
					return err
				}
			}
			if err := cleanupLegacyRuntimeServiceOrphans(effectiveConfig, runner, stdout); err != nil {
				return err
			}
			if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", effectiveConfig.RuntimeService)...); err != nil {
				return err
			}
			if err := runKanbanBootstrap(effectiveConfig, runner, stdout); err != nil {
				return err
			}
			fmt.Fprintf(stdout, "kanban_up mode=external compose_project=%s url=%s runtime_url=%s\n", effectiveConfig.ComposeProject, kanbanPublicURL(effectiveConfig), kanbanRuntimeURL(effectiveConfig))
			return nil
		}
		volumeName := kanbanDataVolumeName(effectiveConfig.ComposeProject)
		volumeExists, err := guardRemovedSoloBoardKanbanData(effectiveConfig, runner)
		if err != nil {
			return err
		}
		if *freshBoard && volumeExists {
			return fmt.Errorf("fresh board requested but kanban volume already exists: %s; use the existing board without --fresh-board, choose a different compose project with a2o project bootstrap, or back up and remove the volume explicitly", volumeName)
		}
		mode := "create_new"
		if volumeExists {
			mode = "reuse_existing"
		}
		fmt.Fprintf(stdout, "kanban_data compose_project=%s volume=%s mode=%s\n", effectiveConfig.ComposeProject, volumeName, mode)
		fmt.Fprintf(stdout, "kanban_backup_hint=docker run --rm -v %s:/data -v \"$PWD\":/backup alpine sh -c 'cp /data/kanbalone.sqlite /backup/kanbalone-%s.sqlite'\n", volumeName, sanitizeBackupName(effectiveConfig.ComposeProject))
		if *build {
			if _, err := runExternal(runner, "docker", append(composePrefix, "build", effectiveConfig.RuntimeService)...); err != nil {
				return err
			}
		}
		if err := cleanupLegacyRuntimeServiceOrphans(effectiveConfig, runner, stdout); err != nil {
			return err
		}
		if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", effectiveConfig.RuntimeService, "kanbalone")...); err != nil {
			return err
		}
		if err := runKanbanBootstrap(effectiveConfig, runner, stdout); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "kanban_up compose_project=%s volume=%s url=%s\n", effectiveConfig.ComposeProject, volumeName, kanbanPublicURL(effectiveConfig))
		return nil
	})
}

func kanbanDataVolumeName(composeProject string) string {
	project := strings.TrimSpace(composeProject)
	if project == "" {
		project = "a2o-runtime"
	}
	return project + "_kanbalone-data"
}

func legacySoloBoardDataVolumeName(composeProject string) string {
	project := strings.TrimSpace(composeProject)
	if project == "" {
		project = "a2o-runtime"
	}
	return project + "_soloboard-data"
}

func guardRemovedSoloBoardKanbanData(config runtimeInstanceConfig, runner commandRunner) (bool, error) {
	volumeName := kanbanDataVolumeName(config.ComposeProject)
	volumeExists, err := dockerVolumeExists(runner, volumeName)
	if err != nil {
		return false, err
	}
	legacyVolumeName := legacySoloBoardDataVolumeName(config.ComposeProject)
	legacyVolumeExists, err := dockerVolumeExists(runner, legacyVolumeName)
	if err != nil {
		return false, err
	}
	if legacyVolumeExists && !volumeExists {
		return false, fmt.Errorf("removed SoloBoard data volume detected: %s; migration_required=true replacement_volume=%s action=copy_or_rename_existing_kanban_data_before_starting_bundled_kanbalone", legacyVolumeName, volumeName)
	}
	if volumeExists {
		hasLegacyDB, err := kanbanVolumeHasLegacySoloBoardDB(runner, volumeName)
		if err != nil {
			return false, err
		}
		if hasLegacyDB {
			return false, fmt.Errorf("removed SoloBoard database file detected in volume %s: soloboard.sqlite; migration_required=true replacement_file=kanbalone.sqlite action=rename_existing_database_file_before_starting_bundled_kanbalone", volumeName)
		}
	}
	return volumeExists, nil
}

func kanbanVolumeHasLegacySoloBoardDB(runner commandRunner, volumeName string) (bool, error) {
	output, err := runner.Run(
		"docker",
		"run",
		"--rm",
		"-v",
		volumeName+":/data",
		"alpine",
		"sh",
		"-c",
		"if [ -f /data/soloboard.sqlite ] && [ ! -f /data/kanbalone.sqlite ]; then echo legacy-soloboard-db; fi",
	)
	if err != nil {
		return false, fmt.Errorf("inspect kanban database files in volume %s: %w", volumeName, err)
	}
	return strings.TrimSpace(string(output)) == "legacy-soloboard-db", nil
}

func dockerVolumeExists(runner commandRunner, volumeName string) (bool, error) {
	if strings.TrimSpace(volumeName) == "" {
		return false, fmt.Errorf("kanban volume name is required")
	}
	output, err := runner.Run("docker", "volume", "inspect", volumeName)
	if err != nil {
		message := strings.ToLower(string(output) + " " + err.Error())
		if strings.Contains(message, "no such volume") || strings.Contains(message, "not found") {
			return false, nil
		}
		return false, fmt.Errorf("inspect kanban volume %s: %w", volumeName, err)
	}
	if strings.TrimSpace(string(output)) == "" {
		return false, nil
	}
	return true, nil
}

func sanitizeBackupName(value string) string {
	name := strings.TrimSpace(value)
	if name == "" {
		return "a2o-runtime"
	}
	replacer := strings.NewReplacer("/", "-", "\\", "-", " ", "-")
	return replacer.Replace(name)
}

func runKanbanBootstrap(config runtimeInstanceConfig, runner commandRunner, stdout io.Writer) error {
	packageConfig, err := loadProjectPackageConfig(config.PackagePath)
	if err != nil {
		return err
	}
	configJSON, err := buildKanbanBootstrapConfigJSON(packageConfig)
	if err != nil {
		return err
	}
	args := append(composeArgs(config), "exec", "-T", config.RuntimeService, "python3", packagedKanbanBootstrapPath, "--config-json", configJSON, "--base-url", kanbanRuntimeURL(config), "--board", packageConfig.KanbanProject)
	if err := runKanbanBootstrapWithRetry(runner, args); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "kanban_bootstrapped project=%s source=project.yaml\n", packageConfig.KanbanProject)
	return nil
}

func buildKanbanBootstrapConfigJSON(config projectPackageConfig) (string, error) {
	boardName := strings.TrimSpace(config.KanbanProject)
	if boardName == "" {
		return "", fmt.Errorf("kanban.project is required")
	}
	tags := kanbanBootstrapTags(config)
	payload := map[string]any{
		"boards": []any{
			map[string]any{
				"name": boardName,
				"tags": tags,
			},
		},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("build kanban bootstrap config: %w", err)
	}
	return string(body), nil
}

func kanbanBootstrapTags(config projectPackageConfig) []map[string]string {
	names := map[string]bool{}
	add := func(name string) {
		name = strings.TrimSpace(name)
		if name != "" {
			names[name] = true
		}
	}
	for _, label := range config.KanbanLabels {
		add(label)
	}
	aliases := make([]string, 0, len(config.Repos))
	for alias := range config.Repos {
		aliases = append(aliases, alias)
	}
	sort.Strings(aliases)
	for _, alias := range aliases {
		label := config.Repos[alias].Label
		if strings.TrimSpace(label) == "" {
			label = "repo:" + alias
		}
		add(label)
	}
	sorted := make([]string, 0, len(names))
	for name := range names {
		sorted = append(sorted, name)
	}
	sort.Strings(sorted)
	tags := make([]map[string]string, 0, len(sorted))
	for _, name := range sorted {
		tags = append(tags, map[string]string{"name": name})
	}
	return tags
}

func runKanbanBootstrapWithRetry(runner commandRunner, args []string) error {
	var lastErr error
	for attempt := 0; attempt < 40; attempt++ {
		if _, err := runExternal(runner, "docker", args...); err == nil {
			return nil
		} else {
			lastErr = err
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("bootstrap kanban project: %w", lastErr)
}

func runKanbanDoctor(args []string, runner commandRunner, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o kanban doctor", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if err := validateRemovedSoloBoardEnvironment(); err != nil {
		return err
	}

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", publicInstanceConfigPath(configPath))
	fmt.Fprintf(stdout, "kanban_mode=%s\n", kanbanMode(effectiveConfig))
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(effectiveConfig))
	if isExternalKanban(effectiveConfig) {
		if err := checkExternalKanbanHealth(kanbanPublicURL(effectiveConfig)); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "kanban_external_health status=ok url=%s\n", kanbanPublicURL(effectiveConfig))
		return nil
	}
	fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
	output, err := runExternal(runner, "docker", append(composeArgs(effectiveConfig), "ps", "kanbalone")...)
	if err != nil {
		return err
	}
	fmt.Fprint(stdout, string(output))
	return nil
}

func runKanbanURL(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o kanban url", flag.ContinueOnError)
	flags.SetOutput(stderr)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if err := validateRemovedSoloBoardEnvironment(); err != nil {
		return err
	}

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, kanbanPublicURL(applyAgentInstallOverrides(*config, "", "", "")))
	return nil
}

func kanbanPublicURL(config runtimeInstanceConfig) string {
	if isExternalKanban(config) {
		return normalizeKanbanBaseURL(config.KanbanURL) + "/"
	}
	return "http://localhost:" + publicKanbanPort(config) + "/"
}

func publicKanbanPort(config runtimeInstanceConfig) string {
	if value := strings.TrimSpace(os.Getenv("A2O_BUNDLE_KANBALONE_PORT")); value != "" {
		return value
	}
	return envDefaultValue(config.KanbalonePort, "3470")
}

func kanbanMode(config runtimeInstanceConfig) string {
	mode := strings.ToLower(strings.TrimSpace(config.KanbanMode))
	if mode == "" {
		return kanbanModeBundled
	}
	return mode
}

func isExternalKanban(config runtimeInstanceConfig) bool {
	return kanbanMode(config) == kanbanModeExternal
}

func normalizeKanbanBaseURL(value string) string {
	return strings.TrimRight(strings.TrimSpace(value), "/")
}

func kanbanRuntimeURL(config runtimeInstanceConfig) string {
	if value := strings.TrimSpace(os.Getenv("A2O_KANBALONE_INTERNAL_URL")); value != "" {
		return normalizeKanbanBaseURL(value)
	}
	if isExternalKanban(config) {
		if value := normalizeKanbanBaseURL(config.KanbanRuntimeURL); value != "" {
			return value
		}
		return dockerReachableKanbanURL(config.KanbanURL)
	}
	return "http://kanbalone:3000"
}

func dockerReachableKanbanURL(value string) string {
	base := normalizeKanbanBaseURL(value)
	parsed, err := url.Parse(base)
	if err != nil || parsed.Host == "" {
		return base
	}
	hostname := parsed.Hostname()
	if hostname != "localhost" && hostname != "127.0.0.1" && hostname != "::1" {
		return base
	}
	if port := parsed.Port(); port != "" {
		parsed.Host = "host.docker.internal:" + port
	} else {
		parsed.Host = "host.docker.internal"
	}
	return strings.TrimRight(parsed.String(), "/")
}

func checkExternalKanbanHealth(baseURL string) error {
	base := normalizeKanbanBaseURL(baseURL)
	if base == "" {
		return fmt.Errorf("external kanban url is required")
	}
	client := http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(base + "/api/health")
	if err != nil {
		return fmt.Errorf("external kanban health check failed url=%s: %w", base, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("external kanban health check failed url=%s status=%s", base, resp.Status)
	}
	return nil
}
