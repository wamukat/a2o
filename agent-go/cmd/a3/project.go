package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

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
	soloBoardPort := flags.String("soloboard-port", "3470", "host kanban service port")
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
