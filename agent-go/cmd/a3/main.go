package main

import (
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
	fmt.Fprintln(w, "  a3 agent target")
	fmt.Fprintln(w, "  a3 agent install --target auto --output PATH [--build] [--compose-project NAME] [--compose-file PATH] [--runtime-service NAME]")
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
	composeProject := flags.String("compose-project", envDefault("A3_COMPOSE_PROJECT", "a3-portal-bundle"), "docker compose project name")
	composeFile := flags.String("compose-file", envDefault("A3_COMPOSE_FILE", defaultComposeFile()), "docker compose file")
	runtimeService := flags.String("runtime-service", envDefault("A3_RUNTIME_SERVICE", "a3-runtime"), "docker compose runtime service name")
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

	composePrefix := []string{"compose", "-p", *composeProject, "-f", *composeFile}
	if *build {
		if _, err := runExternal(runner, "docker", append(composePrefix, "build", *runtimeService)...); err != nil {
			return err
		}
	}
	if _, err := runExternal(runner, "docker", append(composePrefix, "up", "-d", "--no-deps", *runtimeService)...); err != nil {
		return err
	}

	containerBytes, err := runExternal(runner, "docker", append(composePrefix, "ps", "-q", *runtimeService)...)
	if err != nil {
		return err
	}
	containerID := strings.TrimSpace(string(containerBytes))
	if containerID == "" {
		return fmt.Errorf("runtime container not found for service %q", *runtimeService)
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
	candidates := []string{
		"a3-engine/docker/compose/a3-portal-soloboard.yml",
		"../docker/compose/a3-portal-soloboard.yml",
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return candidates[0]
}
