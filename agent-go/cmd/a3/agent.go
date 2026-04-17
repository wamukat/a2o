package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

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
	flags := flag.NewFlagSet("a2o agent install", flag.ContinueOnError)
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
