package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

const version = "dev"
const instanceConfigRelativePath = ".work/a2o/runtime-instance.json"
const legacyInstanceConfigRelativePath = ".a3/runtime-instance.json"
const runtimeHostAgentRelativePath = ".work/a2o/runtime-host-agent"
const hostAgentBinRelativePath = ".work/a2o/agent/bin/a2o-agent"

type commandRunner interface {
	Run(name string, args ...string) ([]byte, error)
	StartBackground(name string, args []string, logPath string) (int, error)
	ProcessRunning(pid int) bool
	ProcessCommand(pid int) string
	TerminateProcessGroup(pid int) error
}

type execRunner struct{}

func (execRunner) Run(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	return cmd.CombinedOutput()
}

func (execRunner) StartBackground(name string, args []string, logPath string) (int, error) {
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		return 0, err
	}
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return 0, err
	}
	defer logFile.Close()
	cmd := exec.Command(name, args...)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return 0, err
	}
	return cmd.Process.Pid, nil
}

func (execRunner) ProcessRunning(pid int) bool {
	return syscall.Kill(pid, 0) == nil
}

func (execRunner) ProcessCommand(pid int) string {
	output, err := exec.Command("ps", "-p", fmt.Sprintf("%d", pid), "-o", "command=").CombinedOutput()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func (execRunner) TerminateProcessGroup(pid int) error {
	if err := syscall.Kill(-pid, syscall.SIGTERM); err == nil {
		return nil
	}
	return syscall.Kill(pid, syscall.SIGTERM)
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
		fmt.Fprintf(stdout, "a2o version=%s\n", version)
		return 0
	case "doctor":
		return runDoctor(args[1:], runner, stdout, stderr)
	case "project":
		return runProject(args[1:], stdout, stderr)
	case "kanban":
		return runKanban(args[1:], runner, stdout, stderr)
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

func isHelpArg(arg string) bool {
	return arg == "help" || arg == "-h" || arg == "--help"
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "usage:")
	fmt.Fprintln(w, "  a2o version")
	fmt.Fprintln(w, "  a2o doctor")
	fmt.Fprintln(w, "  a2o project bootstrap --package DIR")
	fmt.Fprintln(w, "  a2o project template [--language node|go|python|ruby] [--output project.yaml]")
	fmt.Fprintln(w, "  a2o kanban up [--build]")
	fmt.Fprintln(w, "  a2o kanban doctor")
	fmt.Fprintln(w, "  a2o kanban url")
	fmt.Fprintln(w, "  a2o runtime start [--interval DURATION]")
	fmt.Fprintln(w, "  a2o runtime stop")
	fmt.Fprintln(w, "  a2o runtime status")
	fmt.Fprintln(w, "  a2o runtime doctor")
	fmt.Fprintln(w, "  a2o runtime run-once [--max-steps N] [--agent-attempts N]")
	fmt.Fprintln(w, "  a2o runtime loop [--interval DURATION] [--max-cycles N]")
	fmt.Fprintln(w, "  a2o agent target")
	fmt.Fprintln(w, "  a2o agent install --target auto --output PATH [--build]")
}
