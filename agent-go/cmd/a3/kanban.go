package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
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
	freshBoard := flags.Bool("fresh-board", false, "fail if the configured SoloBoard data volume already exists")
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
		volumeName := kanbanDataVolumeName(effectiveConfig.ComposeProject)
		volumeExists, err := dockerVolumeExists(runner, volumeName)
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
		fmt.Fprintf(stdout, "kanban_backup_hint=docker run --rm -v %s:/data -v \"$PWD\":/backup alpine sh -c 'cp /data/soloboard.sqlite /backup/soloboard-%s.sqlite'\n", volumeName, sanitizeBackupName(effectiveConfig.ComposeProject))
		if *build {
			if _, err := runExternal(runner, "docker", append(composePrefix, "build", effectiveConfig.RuntimeService)...); err != nil {
				return err
			}
		}
		if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", effectiveConfig.RuntimeService, "soloboard")...); err != nil {
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
	return project + "_soloboard-data"
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
	projectFile := filepath.Join(config.PackagePath, "project.yaml")
	if _, err := os.Stat(projectFile); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("inspect project package config: %w", err)
	}
	packageConfig, err := loadProjectPackageConfig(config.PackagePath)
	if err != nil {
		return err
	}
	bootstrapPath := strings.TrimSpace(packageConfig.KanbanBootstrap)
	if bootstrapPath == "" {
		return nil
	}
	hostConfigPath := resolvePackagePath(config.PackagePath, bootstrapPath)
	containerConfigPath := workspaceContainerPath(config.WorkspaceRoot, hostConfigPath)
	args := append(composeArgs(config), "exec", "-T", config.RuntimeService, "python3", packagedKanbanBootstrapPath, "--config", containerConfigPath, "--base-url", "http://soloboard:3000")
	if strings.TrimSpace(packageConfig.KanbanProject) != "" {
		args = append(args, "--board", packageConfig.KanbanProject)
	}
	if err := runKanbanBootstrapWithRetry(runner, args); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "kanban_bootstrapped project=%s config=%s\n", packageConfig.KanbanProject, hostConfigPath)
	return nil
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

	config, configPath, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	effectiveConfig := applyAgentInstallOverrides(*config, "", "", "")
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(effectiveConfig))
	fmt.Fprintf(stdout, "compose_project=%s\n", effectiveConfig.ComposeProject)
	output, err := runExternal(runner, "docker", append(composeArgs(effectiveConfig), "ps", "soloboard")...)
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

	config, _, err := loadInstanceConfigFromWorkingTree()
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, kanbanPublicURL(*config))
	return nil
}

func kanbanPublicURL(config runtimeInstanceConfig) string {
	return "http://localhost:" + envDefaultValue(config.SoloBoardPort, "3470") + "/"
}
