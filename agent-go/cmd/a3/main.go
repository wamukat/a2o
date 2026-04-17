package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
)

const version = "dev"
const instanceConfigRelativePath = ".a3/runtime-instance.json"

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

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "usage:")
	fmt.Fprintln(w, "  a2o version")
	fmt.Fprintln(w, "  a2o project bootstrap --package DIR")
	fmt.Fprintln(w, "  a2o kanban up [--build]")
	fmt.Fprintln(w, "  a2o kanban doctor")
	fmt.Fprintln(w, "  a2o kanban url")
	fmt.Fprintln(w, "  a2o runtime doctor")
	fmt.Fprintln(w, "  a2o runtime run-once [--max-steps N] [--agent-attempts N]")
	fmt.Fprintln(w, "  a2o runtime loop [--interval DURATION] [--max-cycles N]")
	fmt.Fprintln(w, "  a2o agent target")
	fmt.Fprintln(w, "  a2o agent install --target auto --output PATH [--build]")
}
