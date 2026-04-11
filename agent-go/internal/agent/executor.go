package agent

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"time"
)

type ExecutionResult struct {
	Status      string
	ExitCode    *int
	CombinedLog []byte
}

type Executor struct{}

func (Executor) Execute(request JobRequest) ExecutionResult {
	timeout := time.Duration(request.TimeoutSeconds) * time.Second
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, request.Command, request.Args...)
	cmd.Dir = request.WorkingDir
	cmd.Env = mergeEnv(request.Env)
	var combined bytes.Buffer
	cmd.Stdout = &combined
	cmd.Stderr = &combined

	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		combined.WriteString("A3 agent command timed out\n")
		return ExecutionResult{Status: "timed_out", ExitCode: nil, CombinedLog: combined.Bytes()}
	}
	if err == nil {
		code := 0
		return ExecutionResult{Status: "succeeded", ExitCode: &code, CombinedLog: combined.Bytes()}
	}
	if errors.Is(err, exec.ErrNotFound) {
		code := 127
		combined.WriteString(err.Error())
		combined.WriteByte('\n')
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: combined.Bytes()}
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code := exitErr.ExitCode()
		return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: combined.Bytes()}
	}
	code := 1
	combined.WriteString(err.Error())
	combined.WriteByte('\n')
	return ExecutionResult{Status: "failed", ExitCode: &code, CombinedLog: combined.Bytes()}
}

func mergeEnv(overrides map[string]string) []string {
	env := os.Environ()
	for key, value := range overrides {
		env = append(env, key+"="+value)
	}
	return env
}
