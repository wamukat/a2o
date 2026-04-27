package agent

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type ExecutionResult struct {
	Status      string
	ExitCode    *int
	Stdout      []byte
	Stderr      []byte
	CombinedLog []byte
}

type Executor struct{}

type bestEffortWriter struct {
	writer io.Writer
}

func (w bestEffortWriter) Write(p []byte) (int, error) {
	if w.writer == nil {
		return len(p), nil
	}
	if _, err := w.writer.Write(p); err != nil {
		return len(p), nil
	}
	return len(p), nil
}

func (Executor) Execute(request JobRequest) ExecutionResult {
	timeout := time.Duration(request.TimeoutSeconds) * time.Second
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, request.Command, request.Args...)
	cmd.Dir = request.WorkingDir
	cmd.Env = mergeEnv(request.Env)
	var combined bytes.Buffer
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	writer, cleanup := liveLogWriterFor(request)
	defer cleanup()
	if writer != nil {
		cmd.Stdout = io.MultiWriter(&stdout, &combined, bestEffortWriter{writer: writer})
		cmd.Stderr = io.MultiWriter(&stderr, &combined, bestEffortWriter{writer: writer})
	} else {
		cmd.Stdout = io.MultiWriter(&stdout, &combined)
		cmd.Stderr = io.MultiWriter(&stderr, &combined)
	}

	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		combined.WriteString("A2O agent command timed out\n")
		stderr.WriteString("A2O agent command timed out\n")
		return ExecutionResult{Status: "timed_out", ExitCode: nil, Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), CombinedLog: combined.Bytes()}
	}
	if err == nil {
		code := 0
		return ExecutionResult{Status: "succeeded", ExitCode: &code, Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), CombinedLog: combined.Bytes()}
	}
	if errors.Is(err, exec.ErrNotFound) {
		code := 127
		combined.WriteString(err.Error())
		combined.WriteByte('\n')
		stderr.WriteString(err.Error())
		stderr.WriteByte('\n')
		return ExecutionResult{Status: "failed", ExitCode: &code, Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), CombinedLog: combined.Bytes()}
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code := exitErr.ExitCode()
		return ExecutionResult{Status: "failed", ExitCode: &code, Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), CombinedLog: combined.Bytes()}
	}
	code := 1
	combined.WriteString(err.Error())
	combined.WriteByte('\n')
	stderr.WriteString(err.Error())
	stderr.WriteByte('\n')
	return ExecutionResult{Status: "failed", ExitCode: &code, Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), CombinedLog: combined.Bytes()}
}

func liveLogWriterFor(request JobRequest) (io.Writer, func()) {
	root := strings.TrimSpace(request.Env["A2O_AGENT_LIVE_LOG_ROOT"])
	if root == "" {
		root = strings.TrimSpace(request.Env["A3_AGENT_LIVE_LOG_ROOT"])
	}
	if root == "" {
		root = os.Getenv("A2O_AGENT_LIVE_LOG_ROOT")
	}
	if strings.TrimSpace(root) == "" {
		root = os.Getenv("A3_AGENT_LIVE_LOG_ROOT")
	}
	if strings.TrimSpace(root) == "" {
		return nil, func() {}
	}
	target := filepath.Join(root, safeID(request.TaskRef), safeID(request.Phase)+".log")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return nil, func() {}
	}
	file, err := os.Create(target)
	if err != nil {
		return nil, func() {}
	}
	return file, func() { _ = file.Close() }
}

func mergeEnv(overrides map[string]string) []string {
	env := os.Environ()
	for key, value := range overrides {
		env = append(env, key+"="+value)
	}
	return env
}
