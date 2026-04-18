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
		if err := runKanbanBootstrap(*config, runner, stdout); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "kanban_up compose_project=%s url=%s\n", config.ComposeProject, kanbanPublicURL(*config))
		return nil
	})
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
	fmt.Fprintf(stdout, "runtime_instance_config=%s\n", configPath)
	fmt.Fprintf(stdout, "kanban_url=%s\n", kanbanPublicURL(*config))
	fmt.Fprintf(stdout, "compose_project=%s\n", config.ComposeProject)
	output, err := runExternal(runner, "docker", append(composeArgs(*config), "ps", "soloboard")...)
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
