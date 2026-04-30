package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/wamukat/a3-engine/agent-go/internal/errorpolicy"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type executorProfile struct {
	Command []string
	Env     map[string]string
}

const maxWorkerResultCorrectionAttempts = 2
const maxInvalidWorkerResultSalvageArtifacts = 5

func envPublic(publicName string) string {
	return strings.TrimSpace(os.Getenv(publicName))
}

func runWorkerStdinBundle(args []string) int {
	if len(args) != 0 {
		fmt.Fprintf(os.Stderr, "unexpected arguments: %s\n", strings.Join(args, " "))
		return 2
	}
	if err := validateRemovedA3WorkerEnvironment(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	requestPath := envPublic("A2O_WORKER_REQUEST_PATH")
	resultPath := envPublic("A2O_WORKER_RESULT_PATH")
	if requestPath == "" || resultPath == "" {
		fmt.Fprintln(os.Stderr, "worker request and result paths are required")
		return 1
	}

	request := map[string]any{}
	if err := readJSONFile(requestPath, &request); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(resultPath), 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	_ = os.Remove(resultPath)

	schemaPath, cleanup, err := writeWorkerResponseSchema(request)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer cleanup()

	command, commandEnv, err := workerExecutorCommand(request, resultPath, schemaPath)
	if err != nil {
		return writeWorkerFailureResult(resultPath, request, workerFailure(request, "stdin worker executor config invalid", []string{"executor", "command"}, "invalid_executor_config", map[string]any{"error": err.Error()}))
	}
	var correction *workerResultCorrection
	for attempt := 0; attempt <= maxWorkerResultCorrectionAttempts; attempt++ {
		_ = os.Remove(resultPath)
		stdout, stderr, exitCode, runErr := runWorkerExecutor(command, commandEnv, workerWorkspaceRoot(), workerBundle(correction))
		if (runErr != nil || exitCode != 0) && !fileExists(resultPath) {
			diagnostics := map[string]any{"stdout": stdout, "stderr": stderr}
			if runErr != nil {
				diagnostics["error"] = runErr.Error()
			}
			return writeWorkerFailureResult(resultPath, request, workerFailure(request, "stdin worker launcher failed", command, fmt.Sprintf("exit %d", exitCode), diagnostics))
		}

		payload := map[string]any{}
		rawResultBody, readErr := os.ReadFile(resultPath)
		if readErr == nil {
			readErr = json.Unmarshal(rawResultBody, &payload)
		}
		if readErr != nil {
			issue := workerValidationIssue{
				Path:    "/",
				Keyword: "required",
				Message: "stdin worker returned no final result",
			}
			observedState := "missing_worker_result"
			if !os.IsNotExist(readErr) {
				issue.Keyword = "type"
				issue.Message = "stdin worker returned invalid json: " + readErr.Error()
				observedState = "invalid_worker_json"
			}
			if attempt < maxWorkerResultCorrectionAttempts {
				correction = newWorkerResultCorrection(attempt+1, []workerValidationIssue{issue}, nil, string(rawResultBody), stdout, stderr)
				continue
			}
			diagnostics := map[string]any{"stdout": stdout, "stderr": stderr, "validation_errors": []workerValidationIssue{issue}}
			if !os.IsNotExist(readErr) {
				diagnostics["error"] = readErr.Error()
				diagnostics["worker_response_raw"] = tailString(string(rawResultBody), 4000)
			}
			if salvage, err := persistInvalidWorkerResultSalvage(request, resultPath, schemaPath, attempt+1, []workerValidationIssue{issue}, nil, string(rawResultBody), stdout, stderr); err == nil {
				diagnostics["invalid_worker_result_salvage"] = salvage
			} else {
				diagnostics["invalid_worker_result_salvage_error"] = err.Error()
			}
			return writeWorkerFailureResult(resultPath, request, workerFailure(request, issue.Message, command, observedState, diagnostics))
		}
		normalizeReviewDisposition(payload, request)
		canonicalizeWorkerIdentity(payload, request)
		if validationErrors := validateWorkerPayload(payload, request); len(validationErrors) > 0 {
			issues := structuredWorkerValidationIssues(validationErrors)
			if attempt < maxWorkerResultCorrectionAttempts {
				correction = newWorkerResultCorrection(attempt+1, issues, payload, "", stdout, stderr)
				continue
			}
			salvage, salvageErr := persistInvalidWorkerResultSalvage(request, resultPath, schemaPath, attempt+1, issues, payload, string(rawResultBody), stdout, stderr)
			diagnostics := map[string]any{
				"validation_errors":      issues,
				"worker_response_bundle": payload,
				"correction_attempts":    maxWorkerResultCorrectionAttempts,
				"stdout":                 stdout,
				"stderr":                 stderr,
			}
			if salvageErr == nil {
				diagnostics["invalid_worker_result_salvage"] = salvage
			} else {
				diagnostics["invalid_worker_result_salvage_error"] = salvageErr.Error()
			}
			return writeWorkerFailureResult(resultPath, request, workerFailure(request, "worker result schema invalid", command, "invalid_worker_result", diagnostics))
		}
		if err := writeJSONFile(resultPath, payload); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		return 0
	}
	return writeWorkerFailureResult(resultPath, request, workerFailure(request, "worker result schema invalid", command, "invalid_worker_result", map[string]any{}))
}

func readJSONFile(path string, target any) error {
	body, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(body, target); err != nil {
		return err
	}
	return nil
}

func writeJSONFile(path string, payload any) error {
	body, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	body = append(body, '\n')
	return os.WriteFile(path, body, 0o600)
}

func writeWorkerFailureResult(resultPath string, request map[string]any, payload map[string]any) int {
	if err := writeJSONFile(resultPath, payload); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
}

type workerValidationIssue struct {
	Path    string `json:"path"`
	Keyword string `json:"keyword"`
	Message string `json:"message"`
}

type workerResultCorrection struct {
	Attempt        int                     `json:"attempt"`
	MaxAttempts    int                     `json:"max_attempts"`
	Instruction    string                  `json:"instruction"`
	Errors         []workerValidationIssue `json:"validation_errors"`
	PreviousResult map[string]any          `json:"previous_result,omitempty"`
	PreviousRaw    string                  `json:"previous_raw,omitempty"`
	StdoutTail     string                  `json:"stdout_tail,omitempty"`
	StderrTail     string                  `json:"stderr_tail,omitempty"`
}

func newWorkerResultCorrection(attempt int, issues []workerValidationIssue, previous map[string]any, previousRaw string, stdout string, stderr string) *workerResultCorrection {
	return &workerResultCorrection{
		Attempt:        attempt,
		MaxAttempts:    maxWorkerResultCorrectionAttempts,
		Instruction:    "The previous worker result did not satisfy the response schema. Do not redo the implementation or review work unless necessary. Return a corrected JSON object only, using the same task_ref, run_ref, and phase from request.",
		Errors:         issues,
		PreviousResult: previous,
		PreviousRaw:    tailString(previousRaw, 4000),
		StdoutTail:     tailString(stdout, 4000),
		StderrTail:     tailString(stderr, 4000),
	}
}

func persistInvalidWorkerResultSalvage(request map[string]any, resultPath string, schemaPath string, attempt int, issues []workerValidationIssue, parsed map[string]any, raw string, stdout string, stderr string) (map[string]any, error) {
	root := filepath.Join(filepath.Dir(resultPath), "invalid-worker-results")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	taskRef := stringValue(request["task_ref"])
	runRef := stringValue(request["run_ref"])
	phase := stringValue(request["phase"])
	fileName := fmt.Sprintf("%s-%s-%s-attempt-%02d.json", safeID(taskRef), safeID(runRef), safeID(phase), attempt)
	if fileName == "---attempt-00.json" {
		fileName = fmt.Sprintf("unknown-%d.json", attempt)
	}
	artifactPath := filepath.Join(root, fileName)
	salvage := map[string]any{
		"schema_name":             "a2o-worker-response",
		"schema_path":             schemaPath,
		"task_ref":                taskRef,
		"run_ref":                 runRef,
		"phase":                   phase,
		"worker_attempt":          attempt,
		"correction_attempts":     maxWorkerResultCorrectionAttempts,
		"created_at":              time.Now().UTC().Format(time.RFC3339),
		"artifact_path":           artifactPath,
		"artifact_relative_path":  filepath.ToSlash(filepath.Join("invalid-worker-results", fileName)),
		"latest_relative_path":    filepath.ToSlash(filepath.Join("invalid-worker-results", "latest.json")),
		"validation_errors":       issues,
		"raw_worker_output":       tailString(raw, 4000),
		"stdout_tail":             tailString(stdout, 4000),
		"stderr_tail":             tailString(stderr, 4000),
		"retention_policy":        "latest pointer plus newest 5 invalid worker result salvage files per worker metadata directory",
		"invalid_result_accepted": false,
	}
	if parsed != nil {
		salvage["parsed_result"] = parsed
	}
	if err := writeJSONFile(artifactPath, salvage); err != nil {
		return nil, err
	}
	latestPath := filepath.Join(root, "latest.json")
	if err := writeJSONFile(latestPath, salvage); err != nil {
		return nil, err
	}
	cleanupInvalidWorkerResultSalvage(root, fileName)
	return map[string]any{
		"schema_name":            salvage["schema_name"],
		"task_ref":               taskRef,
		"run_ref":                runRef,
		"phase":                  phase,
		"worker_attempt":         attempt,
		"artifact_path":          artifactPath,
		"artifact_relative_path": salvage["artifact_relative_path"],
		"latest_relative_path":   salvage["latest_relative_path"],
		"validation_errors":      issues,
		"retention_policy":       salvage["retention_policy"],
	}, nil
}

func cleanupInvalidWorkerResultSalvage(root string, keepName string) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	type salvageFile struct {
		name    string
		modTime time.Time
	}
	files := []salvageFile{}
	for _, entry := range entries {
		if entry.IsDir() || entry.Name() == "latest.json" || entry.Name() == keepName || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		files = append(files, salvageFile{name: entry.Name(), modTime: info.ModTime()})
	}
	sort.Slice(files, func(i, j int) bool {
		return files[i].modTime.After(files[j].modTime)
	})
	retainedOtherFiles := maxInvalidWorkerResultSalvageArtifacts - 1
	if len(files) <= retainedOtherFiles {
		return
	}
	for _, file := range files[retainedOtherFiles:] {
		_ = os.Remove(filepath.Join(root, file.name))
	}
}

func latestInvalidWorkerResultSalvage(resultPath string) map[string]any {
	latestPath := filepath.Join(filepath.Dir(resultPath), "invalid-worker-results", "latest.json")
	payload := map[string]any{}
	if err := readJSONFile(latestPath, &payload); err != nil {
		return nil
	}
	return payload
}

func structuredWorkerValidationIssues(messages []string) []workerValidationIssue {
	issues := make([]workerValidationIssue, 0, len(messages))
	for _, message := range messages {
		issues = append(issues, structuredWorkerValidationIssue(message))
	}
	return issues
}

func structuredWorkerValidationIssue(message string) workerValidationIssue {
	path := "/"
	keyword := "validation"
	switch {
	case strings.Contains(message, " must be present"):
		path = "/" + strings.Split(message, " must be present")[0]
		keyword = "required"
	case strings.Contains(message, " must be a string"), strings.Contains(message, " must be true or false"), strings.Contains(message, " must be an object"), strings.Contains(message, " must be an array"):
		path = "/" + strings.Split(message, " must be ")[0]
		keyword = "type"
	case strings.Contains(message, " must be one of "):
		path = "/" + strings.Split(message, " must be one of ")[0]
		keyword = "enum"
	case strings.Contains(message, " must match "):
		path = "/" + strings.Split(message, " must match ")[0]
		keyword = "const"
	case strings.Contains(message, " must only be present"):
		path = "/" + strings.Split(message, " must only be present")[0]
		keyword = "dependentRequired"
	}
	return workerValidationIssue{
		Path:    strings.ReplaceAll(path, ".", "/"),
		Keyword: keyword,
		Message: message,
	}
}

func tailString(value string, limit int) string {
	if limit <= 0 || len(value) <= limit {
		return value
	}
	return value[len(value)-limit:]
}

func workerFailure(request map[string]any, summary string, command []string, observedState string, diagnostics map[string]any) map[string]any {
	category := errorpolicy.WorkerCategory(summary, observedState, stringValue(request["phase"]))
	enrichedDiagnostics := map[string]any{}
	for key, value := range diagnostics {
		enrichedDiagnostics[key] = sanitizeWorkerDiagnosticValue(value)
	}
	enrichedDiagnostics["error_category"] = category
	enrichedDiagnostics["remediation"] = errorpolicy.WorkerRemediation(category)
	payload := map[string]any{
		"task_ref":        stringValue(request["task_ref"]),
		"run_ref":         stringValue(request["run_ref"]),
		"phase":           stringValue(request["phase"]),
		"success":         false,
		"summary":         summary,
		"failing_command": sanitizeWorkerDiagnosticString(strings.Join(command, " ")),
		"observed_state":  observedState,
		"rework_required": false,
		"diagnostics":     enrichedDiagnostics,
	}
	if stringValue(request["phase"]) == "review" && nestedString(request, "phase_runtime", "task_kind") == "parent" {
		payload["review_disposition"] = map[string]any{
			"kind":        "blocked",
			"slot_scopes": []string{"unresolved"},
			"summary":     summary,
			"description": fmt.Sprintf("Parent review failed before producing a canonical review disposition. observed_state=%s", observedState),
			"finding_key": "parent-review-runtime-failure",
		}
	}
	return payload
}

func sanitizeWorkerDiagnosticValue(value any) any {
	switch typed := value.(type) {
	case string:
		return sanitizeWorkerDiagnosticString(typed)
	case []any:
		sanitized := make([]any, 0, len(typed))
		for _, item := range typed {
			sanitized = append(sanitized, sanitizeWorkerDiagnosticValue(item))
		}
		return sanitized
	case map[string]any:
		sanitized := map[string]any{}
		for key, item := range typed {
			sanitized[key] = sanitizeWorkerDiagnosticValue(item)
		}
		return sanitized
	default:
		return value
	}
}

func sanitizeWorkerDiagnosticString(value string) string {
	replacer := strings.NewReplacer(
		"A3_WORKER_REQUEST_PATH", "A2O_WORKER_REQUEST_PATH",
		"A3_WORKER_RESULT_PATH", "A2O_WORKER_RESULT_PATH",
		"A3_WORKSPACE_ROOT", "A2O_WORKSPACE_ROOT",
		"A3_WORKER_LAUNCHER_CONFIG_PATH", "A2O_WORKER_LAUNCHER_CONFIG_PATH",
		"A3_ROOT_DIR", "A2O_ROOT_DIR",
		"/tmp/a3-engine/lib/a3", "<runtime-preset-dir>/lib/a2o-internal",
		"/tmp/a3-engine", "<runtime-preset-dir>",
		"/usr/local/bin/a3", "<engine-entrypoint>",
		"lib/a3", "lib/a2o-internal",
		".a2o", "<agent-metadata>",
		".a3", "<agent-metadata>",
	)
	return replacer.Replace(value)
}

func workerWorkspaceRoot() string {
	if root := envPublic("A2O_WORKSPACE_ROOT"); root != "" {
		return root
	}
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return wd
}

func validateRemovedA3WorkerEnvironment() error {
	replacements := map[string]string{
		"A3_WORKER_REQUEST_PATH":         "A2O_WORKER_REQUEST_PATH",
		"A3_WORKER_RESULT_PATH":          "A2O_WORKER_RESULT_PATH",
		"A3_WORKSPACE_ROOT":              "A2O_WORKSPACE_ROOT",
		"A3_WORKER_LAUNCHER_CONFIG_PATH": "A2O_WORKER_LAUNCHER_CONFIG_PATH",
		"A3_ROOT_DIR":                    "A2O_ROOT_DIR",
		"A3_AGENT_AI_RAW_LOG_ROOT":       "A2O_AGENT_AI_RAW_LOG_ROOT",
	}
	for removed, replacement := range replacements {
		if strings.TrimSpace(os.Getenv(removed)) != "" {
			return removedA3AgentInputError("environment variable "+removed, "environment variable "+replacement)
		}
	}
	return nil
}

func writeWorkerResponseSchema(request map[string]any) (string, func(), error) {
	file, err := os.CreateTemp("", "a2o-worker-schema-*.json")
	if err != nil {
		return "", func() {}, err
	}
	properties := map[string]any{
		"task_ref":        map[string]any{"type": "string"},
		"run_ref":         map[string]any{"type": "string"},
		"phase":           map[string]any{"type": "string"},
		"success":         map[string]any{"type": "boolean"},
		"summary":         map[string]any{"type": "string"},
		"failing_command": map[string]any{"type": []string{"string", "null"}},
		"observed_state":  map[string]any{"type": []string{"string", "null"}},
		"rework_required": map[string]any{"type": "boolean"},
		"clarification_request": map[string]any{
			"type": []string{"object", "null"},
			"properties": map[string]any{
				"question":           map[string]any{"type": "string"},
				"context":            map[string]any{"type": "string"},
				"options":            map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
				"recommended_option": map[string]any{"type": "string"},
				"impact":             map[string]any{"type": "string"},
			},
			"required":             []string{"question"},
			"additionalProperties": false,
		},
	}
	if stringValue(request["phase"]) == "implementation" {
		properties["changed_files"] = map[string]any{
			"type": []string{"object", "null"},
			"additionalProperties": map[string]any{
				"type":  "array",
				"items": map[string]any{"type": "string"},
			},
		}
		properties["review_disposition"] = reviewDispositionSchema([]string{"object", "null"})
	}
	if stringValue(request["phase"]) == "review" && nestedString(request, "phase_runtime", "task_kind") == "parent" {
		properties["review_disposition"] = reviewDispositionSchema("object")
	}
	schema := map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             workerRequiredFields(request),
		"properties":           properties,
	}
	body, err := json.MarshalIndent(schema, "", "  ")
	if err != nil {
		_ = file.Close()
		_ = os.Remove(file.Name())
		return "", func() {}, err
	}
	if _, err := file.Write(append(body, '\n')); err != nil {
		_ = file.Close()
		_ = os.Remove(file.Name())
		return "", func() {}, err
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(file.Name())
		return "", func() {}, err
	}
	return file.Name(), func() { _ = os.Remove(file.Name()) }, nil
}

func reviewDispositionSchema(schemaType any) map[string]any {
	return map[string]any{
		"type": schemaType,
		"properties": map[string]any{
			"kind":        map[string]any{"type": "string"},
			"slot_scopes": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "minItems": 1},
			"summary":     map[string]any{"type": "string"},
			"description": map[string]any{"type": "string"},
			"finding_key": map[string]any{"type": "string"},
		},
		"required":             []string{"kind", "slot_scopes", "summary", "description", "finding_key"},
		"additionalProperties": false,
	}
}

func workerRequiredFields(request map[string]any) []string {
	fields := []string{"task_ref", "run_ref", "phase", "success", "summary", "rework_required"}
	return fields
}

func workerExecutorCommand(request map[string]any, resultPath string, schemaPath string) ([]string, map[string]string, error) {
	config := map[string]any{}
	launcherConfigPath := workerLauncherConfigPath()
	if launcherConfigPath == "" {
		return nil, nil, fmt.Errorf("A2O_WORKER_LAUNCHER_CONFIG_PATH is required for a2o-agent worker stdin-bundle")
	}
	if err := readJSONFile(launcherConfigPath, &config); err != nil {
		return nil, nil, err
	}
	rawExecutor, ok := config["executor"].(map[string]any)
	if !ok {
		return nil, nil, fmt.Errorf("executor must be an object")
	}
	profile, err := resolveWorkerExecutorProfile(request, rawExecutor)
	if err != nil {
		return nil, nil, err
	}
	command := make([]string, 0, len(profile.Command))
	for _, arg := range profile.Command {
		expanded, err := expandWorkerPlaceholder(arg, resultPath, schemaPath)
		if err != nil {
			return nil, nil, err
		}
		command = append(command, expanded)
	}
	return command, profile.Env, nil
}

func workerLauncherConfigPath() string {
	return envPublic("A2O_WORKER_LAUNCHER_CONFIG_PATH")
}

func resolveWorkerExecutorProfile(request map[string]any, executor map[string]any) (executorProfile, error) {
	if stringValue(executor["kind"]) != "command" {
		return executorProfile{}, fmt.Errorf("executor.kind must be command")
	}
	if stringValue(executor["prompt_transport"]) != "stdin-bundle" {
		return executorProfile{}, fmt.Errorf("executor.prompt_transport must be stdin-bundle")
	}
	result, ok := executor["result"].(map[string]any)
	if !ok || stringValue(result["mode"]) != "file" {
		return executorProfile{}, fmt.Errorf("executor.result.mode must be file")
	}
	schema, ok := executor["schema"].(map[string]any)
	if !ok || !containsString([]string{"file", "none"}, stringValue(schema["mode"])) {
		return executorProfile{}, fmt.Errorf("executor.schema.mode must be file or none")
	}
	defaultProfile, err := normalizeExecutorProfile(executor["default_profile"], "executor.default_profile")
	if err != nil {
		return executorProfile{}, err
	}
	phaseProfiles := map[string]any{}
	if raw, ok := executor["phase_profiles"].(map[string]any); ok {
		phaseProfiles = raw
	} else if executor["phase_profiles"] != nil {
		return executorProfile{}, fmt.Errorf("executor.phase_profiles must be an object")
	}
	phaseKey, err := workerExecutorPhase(request)
	if err != nil {
		return executorProfile{}, err
	}
	rawPhaseProfile, ok := phaseProfiles[phaseKey]
	if !ok {
		return defaultProfile, nil
	}
	phaseProfile, err := normalizeExecutorProfile(rawPhaseProfile, "executor.phase_profiles."+phaseKey)
	if err != nil {
		return executorProfile{}, err
	}
	env := map[string]string{}
	for key, value := range defaultProfile.Env {
		env[key] = value
	}
	for key, value := range phaseProfile.Env {
		env[key] = value
	}
	phaseProfile.Env = env
	return phaseProfile, nil
}

func normalizeExecutorProfile(raw any, label string) (executorProfile, error) {
	profile, ok := raw.(map[string]any)
	if !ok {
		return executorProfile{}, fmt.Errorf("%s must be an object", label)
	}
	rawCommand, ok := profile["command"].([]any)
	if !ok || len(rawCommand) == 0 {
		return executorProfile{}, fmt.Errorf("%s.command must be a non-empty array of non-empty strings", label)
	}
	command := make([]string, 0, len(rawCommand))
	for _, entry := range rawCommand {
		value := stringValue(entry)
		if value == "" {
			return executorProfile{}, fmt.Errorf("%s.command must be a non-empty array of non-empty strings", label)
		}
		command = append(command, value)
	}
	env, err := normalizeStringMap(profile["env"], label+".env")
	if err != nil {
		return executorProfile{}, err
	}
	return executorProfile{Command: command, Env: env}, nil
}

func workerExecutorPhase(request map[string]any) (string, error) {
	phase := stringValue(request["phase"])
	if phase == "review" && nestedString(request, "phase_runtime", "task_kind") == "parent" {
		return "parent_review", nil
	}
	if phase == "implementation" || phase == "review" {
		return phase, nil
	}
	return "", fmt.Errorf("unsupported executor phase %q", phase)
}

func expandWorkerPlaceholder(arg string, resultPath string, schemaPath string) (string, error) {
	replacer := strings.NewReplacer(
		"{{result_path}}", resultPath,
		"{{schema_path}}", schemaPath,
		"{{workspace_root}}", workerWorkspaceRoot(),
		"{{a2o_root_dir}}", workerRootDir(),
		"{{root_dir}}", workerRootDir(),
	)
	expanded := replacer.Replace(arg)
	if strings.Contains(expanded, "{{") || strings.Contains(expanded, "}}") {
		return "", fmt.Errorf("unknown executor command placeholder in %q", arg)
	}
	return expanded, nil
}

func workerRootDir() string {
	if root := strings.TrimSpace(os.Getenv("A2O_ROOT_DIR")); root != "" {
		return root
	}
	return workerWorkspaceRoot()
}

type bestEffortBundleWriter struct {
	writer io.Writer
}

func (w bestEffortBundleWriter) Write(p []byte) (int, error) {
	if w.writer == nil {
		return len(p), nil
	}
	if _, err := w.writer.Write(p); err != nil {
		return len(p), nil
	}
	return len(p), nil
}

func runWorkerExecutor(command []string, commandEnv map[string]string, workspaceRoot string, bundle string) (string, string, int, error) {
	if len(command) == 0 {
		return "", "", 1, fmt.Errorf("executor command is empty")
	}
	cmd := exec.Command(command[0], command[1:]...)
	cmd.Dir = workspaceRoot
	env := os.Environ()
	env = append(env, "PWD="+workspaceRoot)
	for _, key := range sortedKeys(commandEnv) {
		env = append(env, key+"="+commandEnv[key])
	}
	cmd.Env = env
	cmd.Stdin = strings.NewReader(bundle)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	rawWriter, cleanup := workerAIRawLogWriter()
	defer cleanup()
	if rawWriter != nil {
		cmd.Stdout = io.MultiWriter(&stdout, bestEffortBundleWriter{writer: rawWriter})
		cmd.Stderr = io.MultiWriter(&stderr, bestEffortBundleWriter{writer: rawWriter})
	} else {
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
	}
	err := cmd.Run()
	if err == nil {
		return stdout.String(), stderr.String(), 0, nil
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		return stdout.String(), stderr.String(), exitErr.ExitCode(), err
	}
	return stdout.String(), stderr.String(), 1, err
}

func workerAIRawLogWriter() (io.Writer, func()) {
	root := envPublic("A2O_AGENT_AI_RAW_LOG_ROOT")
	if root == "" {
		return nil, func() {}
	}
	taskRef := safeID(stringValue(workerRequestValue("task_ref")))
	phase := safeID(stringValue(workerRequestValue("phase")))
	if taskRef == "" || phase == "" {
		return nil, func() {}
	}
	target := filepath.Join(root, taskRef, phase+".log")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return nil, func() {}
	}
	file, err := os.Create(target)
	if err != nil {
		return nil, func() {}
	}
	return file, func() { _ = file.Close() }
}

func workerBundle(correction *workerResultCorrection) string {
	request := map[string]any{}
	_ = readJSONFile(envPublic("A2O_WORKER_REQUEST_PATH"), &request)
	examples := []map[string]any{}
	if stringValue(request["phase"]) == "review" && nestedString(request, "phase_runtime", "task_kind") == "parent" {
		examples = parentReviewResponseExamples(request)
	}
	bundle := map[string]any{
		"type":        "a2o-worker-stdin-bundle",
		"instruction": workerInstruction(request),
		"request":     request,
		"response_contract": map[string]any{
			"mode":          "json-object",
			"required_keys": workerRequiredFields(request),
			"notes": []string{
				"Return a single JSON object only.",
				"Always include task_ref, run_ref, phase, success, summary, and rework_required.",
				"Use null for failing_command and observed_state when success is true.",
				"For failures, include failing_command and observed_state unless you return clarification_request.",
				"When requirements are ambiguous or conflicting and you cannot safely continue, return success=false, rework_required=false, and clarification_request with question, optional context/options/recommended_option/impact. This is for requester input, not runtime or validation failures.",
				"For implementation success, include changed_files keyed by slot name with relative paths to publish.",
				"For implementation success, include review_disposition with kind=completed when self-review is clean.",
				"For review failures caused by findings, include rework_required=true.",
				"For parent review, include review_disposition with kind, slot_scopes, summary, description, and finding_key unless you return clarification_request.",
				"Copy task_ref, run_ref, and phase exactly from request. If you are uncertain, omit them rather than inventing values.",
				"For parent review success with no findings, set success=true, observed_state=null, rework_required=false, and review_disposition.kind=completed.",
				"For parent review code follow-up findings, set success=false, observed_state to a concise string such as review_findings, rework_required=false, and review_disposition.kind=follow_up_child with configured slot_scopes.",
				"For parent review blocked findings, set success=false, observed_state to a concise string such as blocked_finding, rework_required=false, and review_disposition.kind=blocked with slot_scopes=[unresolved].",
			},
			"examples": examples,
		},
		"operating_contract": map[string]any{
			"workspace_root": envPublic("A2O_WORKSPACE_ROOT"),
			"slot_paths":     mapValue(request["slot_paths"]),
			"phase_runtime":  mapValue(request["phase_runtime"]),
			"rules": []string{
				"Only inspect and modify files under slot_paths.",
				"Read request.task_packet.title and request.task_packet.description before planning work.",
				"Treat phase_runtime.verification_commands as runner-owned unless explicitly needed for the phase.",
			},
		},
	}
	if correction != nil {
		bundle["result_correction"] = correction
	} else if salvage := latestInvalidWorkerResultSalvage(envPublic("A2O_WORKER_RESULT_PATH")); salvage != nil {
		bundle["previous_invalid_worker_result"] = salvage
	}
	body, _ := json.MarshalIndent(bundle, "", "  ")
	return string(body)
}

func parentReviewResponseExamples(request map[string]any) []map[string]any {
	slotScope := "repo_alpha"
	scopes := validWorkerReviewDispositionSlotScopes(request, true)
	for _, scope := range scopes {
		if scope != "unresolved" {
			slotScope = scope
			break
		}
	}
	base := map[string]any{
		"task_ref": request["task_ref"],
		"run_ref":  request["run_ref"],
		"phase":    request["phase"],
	}
	clean := copyMap(base)
	clean["success"] = true
	clean["summary"] = "Parent review found no findings."
	clean["failing_command"] = nil
	clean["observed_state"] = nil
	clean["rework_required"] = false
	clean["review_disposition"] = map[string]any{
		"kind":        "completed",
		"slot_scopes": []string{slotScope},
		"summary":     "No findings",
		"description": "The parent integration branch is ready to complete.",
		"finding_key": "no-findings",
	}
	followUp := copyMap(base)
	followUp["success"] = false
	followUp["summary"] = "A follow-up child task is required."
	followUp["failing_command"] = nil
	followUp["observed_state"] = "review_findings"
	followUp["rework_required"] = false
	followUp["review_disposition"] = map[string]any{
		"kind":        "follow_up_child",
		"slot_scopes": []string{slotScope},
		"summary":     "Follow-up child required",
		"description": "The finding is scoped to one configured slot and should be implemented as a child task.",
		"finding_key": "parent-review-follow-up",
	}
	blocked := copyMap(base)
	blocked["success"] = false
	blocked["summary"] = "Parent review is blocked."
	blocked["failing_command"] = "parent_review"
	blocked["observed_state"] = "blocked_finding"
	blocked["rework_required"] = false
	blocked["review_disposition"] = map[string]any{
		"kind":        "blocked",
		"slot_scopes": []string{"unresolved"},
		"summary":     "Parent review blocked",
		"description": "The finding cannot be routed to a configured child scope without requester input or technical resolution.",
		"finding_key": "parent-review-blocked",
	}
	return []map[string]any{
		{"name": "parent_review_clean", "response": clean},
		{"name": "parent_review_follow_up_child", "response": followUp},
		{"name": "parent_review_blocked", "response": blocked},
	}
}

func copyMap(values map[string]any) map[string]any {
	copied := map[string]any{}
	for key, value := range values {
		copied[key] = value
	}
	return copied
}

func workerRequestValue(key string) any {
	request := map[string]any{}
	if err := readJSONFile(envPublic("A2O_WORKER_REQUEST_PATH"), &request); err != nil {
		return nil
	}
	return request[key]
}

func safeID(value string) string {
	var builder strings.Builder
	for _, ch := range value {
		switch {
		case ch >= 'A' && ch <= 'Z':
			builder.WriteRune(ch)
		case ch >= 'a' && ch <= 'z':
			builder.WriteRune(ch)
		case ch >= '0' && ch <= '9':
			builder.WriteRune(ch)
		case ch == '.', ch == '_', ch == '-', ch == ':':
			builder.WriteRune(ch)
		default:
			builder.WriteByte('-')
		}
	}
	return builder.String()
}

func workerInstruction(request map[string]any) string {
	phase := stringValue(request["phase"])
	instruction := "You are the A2O worker. Work only under slot_paths. Follow AGENTS.md and repo Taskfile conventions. Do not update kanban directly. Treat request.task_packet as the primary source of truth for what to implement or review before inferring from repository context. Return only the final JSON object required by response_contract."
	if phase == "implementation" {
		return instruction + " For implementation success, make the required code change, leave git staging/commit publication to the outer A2O runtime, and include changed_files keyed by slot name with relative paths to publish. After you finish implementation, perform a final self-review before returning. When that self-review is clean, include review_disposition with kind=completed so the outer runtime can preserve review evidence without a separate review phase."
	}
	if phase == "review" && nestedString(request, "phase_runtime", "task_kind") == "parent" {
		return instruction + " For parent review, include review_disposition unless you return clarification_request. Use kind=completed when review is clean, kind=follow_up_child with slot_scopes for code follow-up, and kind=blocked with slot_scopes=[unresolved] when the finding should block the parent. Use clarification_request instead when the finding needs requester input rather than code follow-up or technical blocking. Parent review must not rely on rework_required routing."
	}
	if phase == "review" {
		return instruction + " For review, report success only when you found no findings; otherwise return success=false with a short summary and set rework_required=true for code findings that should go back to implementation. Reserve rework_required=false for infrastructure or launch failures that should stay blocked. For review findings, you may set failing_command to null."
	}
	return instruction
}

func validateWorkerPayload(payload map[string]any, request map[string]any) []string {
	errors := []string{}
	required := workerRequiredFields(request)
	for _, key := range required {
		if _, ok := payload[key]; !ok {
			errors = append(errors, key+" must be present")
		}
	}
	if stringValue(payload["task_ref"]) != "" && stringValue(payload["task_ref"]) != stringValue(request["task_ref"]) {
		errors = append(errors, "task_ref must match the worker request")
	}
	if stringValue(payload["run_ref"]) != "" && stringValue(payload["run_ref"]) != stringValue(request["run_ref"]) {
		errors = append(errors, "run_ref must match the worker request")
	}
	if stringValue(payload["phase"]) != "" && stringValue(payload["phase"]) != stringValue(request["phase"]) {
		errors = append(errors, "phase must match the worker request")
	}
	if _, ok := payload["success"].(bool); !ok {
		errors = append(errors, "success must be true or false")
	}
	if _, ok := payload["summary"].(string); !ok {
		errors = append(errors, "summary must be a string")
	}
	if _, ok := payload["rework_required"].(bool); !ok {
		errors = append(errors, "rework_required must be true or false")
	}
	success, _ := payload["success"].(bool)
	if !success {
		clarification := clarificationRequestPresent(payload)
		if rework, _ := payload["rework_required"].(bool); !rework && !clarification && stringValue(payload["failing_command"]) == "" {
			errors = append(errors, "failing_command must be a string when success is false unless rework_required is true")
		}
		if !clarification && stringValue(payload["observed_state"]) == "" {
			errors = append(errors, "observed_state must be a string when success is false")
		}
	}
	if _, ok := payload["clarification_request"]; ok {
		errors = append(errors, validateClarificationRequest(payload["clarification_request"], success)...)
	}
	if stringValue(request["phase"]) == "implementation" && success {
		if _, ok := payload["changed_files"].(map[string]any); !ok {
			errors = append(errors, "changed_files must be present for implementation success")
		}
	}
	if needsReviewDisposition(request, success) && !clarificationRequestPresent(payload) {
		disposition, ok := payload["review_disposition"].(map[string]any)
		if !ok {
			if stringValue(request["phase"]) == "implementation" {
				errors = append(errors, "review_disposition must be present for implementation success")
			} else {
				errors = append(errors, "review_disposition must be present for parent review")
			}
		} else {
			for _, key := range []string{"kind", "summary", "description", "finding_key"} {
				if stringValue(disposition[key]) == "" {
					errors = append(errors, "review_disposition."+key+" must be a string")
				}
			}
			if _, ok := disposition["repo_scope"]; ok {
				errors = append(errors, "review_disposition.repo_scope is not supported; use review_disposition.slot_scopes")
			}
			errors = append(errors, validateWorkerReviewDispositionSlotScopes(disposition["slot_scopes"])...)
			errors = append(errors, validateWorkerReviewDisposition(disposition, request, success)...)
		}
	}
	return errors
}

func validateWorkerReviewDisposition(disposition map[string]any, request map[string]any, success bool) []string {
	phase := stringValue(request["phase"])
	parentReview := phase == "review" && nestedString(request, "phase_runtime", "task_kind") == "parent"
	validScopes := validWorkerReviewDispositionSlotScopes(request, parentReview)
	slotScopes := stringSliceValue(disposition["slot_scopes"])
	errors := []string{}
	if parentReview {
		validKinds := []string{"completed", "follow_up_child", "blocked"}
		if !containsString(validKinds, stringValue(disposition["kind"])) {
			errors = append(errors, "review_disposition.kind must be one of "+strings.Join(validKinds, ", "))
		}
		if invalid := invalidStringMembers(slotScopes, validScopes); len(invalid) > 0 {
			errors = append(errors, "review_disposition.slot_scopes must be one of "+strings.Join(validScopes, ", "))
		}
		if success && stringValue(disposition["kind"]) != "completed" {
			errors = append(errors, "review_disposition.kind must be completed when success is true for parent review")
		}
		return errors
	}
	if phase == "implementation" {
		if stringValue(disposition["kind"]) != "completed" {
			errors = append(errors, "review_disposition.kind must be completed for implementation evidence")
		}
		if invalid := invalidStringMembers(slotScopes, validScopes); len(invalid) > 0 {
			errors = append(errors, "review_disposition.slot_scopes must be one of "+strings.Join(validScopes, ", "))
		}
	}
	return errors
}

func canonicalizeWorkerIdentity(payload map[string]any, request map[string]any) {
	for _, key := range []string{"task_ref", "run_ref", "phase"} {
		value, ok := payload[key]
		if !ok || value == request[key] {
			continue
		}
		diagnostics, _ := payload["diagnostics"].(map[string]any)
		if diagnostics == nil {
			diagnostics = map[string]any{}
		}
		corrections, _ := diagnostics["canonicalized_identity"].(map[string]any)
		if corrections == nil {
			corrections = map[string]any{}
		}
		corrections[key] = map[string]any{
			"provided":  value,
			"canonical": request[key],
		}
		diagnostics["canonicalized_identity"] = corrections
		payload["diagnostics"] = diagnostics
		payload[key] = request[key]
	}
}

func clarificationRequestPresent(payload map[string]any) bool {
	_, ok := payload["clarification_request"].(map[string]any)
	return ok
}

func validateClarificationRequest(value any, success bool) []string {
	if value == nil {
		return nil
	}
	request, ok := value.(map[string]any)
	if !ok {
		return []string{"clarification_request must be an object when present"}
	}
	errors := []string{}
	if success {
		errors = append(errors, "clarification_request must only be present when success is false")
	}
	if strings.TrimSpace(stringValue(request["question"])) == "" {
		errors = append(errors, "clarification_request.question must be a non-empty string")
	}
	for _, field := range []string{"context", "recommended_option", "impact"} {
		if raw, ok := request[field]; ok && raw != nil {
			if _, ok := raw.(string); !ok {
				errors = append(errors, "clarification_request."+field+" must be a string when present")
			}
		}
	}
	if rawOptions, ok := request["options"]; ok {
		options, ok := rawOptions.([]any)
		if !ok {
			errors = append(errors, "clarification_request.options must be an array of non-empty strings")
		} else {
			for _, option := range options {
				if strings.TrimSpace(stringValue(option)) == "" {
					errors = append(errors, "clarification_request.options must be an array of non-empty strings")
					break
				}
			}
		}
	}
	return errors
}

func needsReviewDisposition(request map[string]any, success bool) bool {
	phase := stringValue(request["phase"])
	return (phase == "implementation" && success) || (phase == "review" && nestedString(request, "phase_runtime", "task_kind") == "parent")
}

func normalizeReviewDisposition(payload map[string]any, request map[string]any) {
	normalizeParentReviewSuccess(payload, request)
}

func normalizeParentReviewSuccess(payload map[string]any, request map[string]any) {
	if stringValue(request["phase"]) != "review" || nestedString(request, "phase_runtime", "task_kind") != "parent" {
		return
	}
	if success, _ := payload["success"].(bool); !success {
		return
	}
	if reworkRequired, ok := payload["rework_required"].(bool); !ok || reworkRequired {
		return
	}

	disposition, _ := payload["review_disposition"].(map[string]any)
	if kind := stringValue(disposition["kind"]); kind != "" && kind != "completed" {
		return
	}
	normalized := map[string]any{}
	for key, value := range disposition {
		normalized[key] = value
	}
	normalized["kind"] = "completed"
	if len(stringSliceValue(normalized["slot_scopes"])) == 0 {
		normalized["slot_scopes"] = []string{defaultParentReviewSlotScope(request)}
	}
	if stringValue(normalized["summary"]) == "" {
		normalized["summary"] = stringValue(payload["summary"])
	}
	if stringValue(normalized["description"]) == "" {
		normalized["description"] = stringValue(payload["summary"])
	}
	if stringValue(normalized["finding_key"]) == "" {
		normalized["finding_key"] = "parent-review-completed"
	}
	payload["review_disposition"] = normalized
}

func defaultParentReviewSlotScope(request map[string]any) string {
	scopes := validWorkerReviewDispositionSlotScopes(request, true)
	for _, scope := range scopes {
		if scope != "unresolved" {
			return scope
		}
	}
	return "unresolved"
}

func normalizeStringMap(raw any, label string) (map[string]string, error) {
	if raw == nil {
		return map[string]string{}, nil
	}
	values, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s must be an object", label)
	}
	normalized := map[string]string{}
	for key, value := range values {
		stringValue, ok := value.(string)
		if key == "" || !ok {
			return nil, fmt.Errorf("%s keys and values must be strings", label)
		}
		normalized[key] = stringValue
	}
	return normalized, nil
}

func stringValue(value any) string {
	text, _ := value.(string)
	return text
}

func nestedString(values map[string]any, keys ...string) string {
	var current any = values
	for _, key := range keys {
		currentMap, ok := current.(map[string]any)
		if !ok {
			return ""
		}
		current = currentMap[key]
	}
	return stringValue(current)
}

func mapValue(value any) map[string]any {
	values, ok := value.(map[string]any)
	if !ok {
		return map[string]any{}
	}
	return values
}

func validWorkerReviewDispositionSlotScopes(request map[string]any, includeUnresolved bool) []string {
	scopes := configuredWorkerReviewDispositionSlotScopes()
	if len(scopes) == 0 {
		for scope := range mapValue(request["slot_paths"]) {
			if scope != "" && !containsString(scopes, scope) {
				scopes = append(scopes, scope)
			}
		}
	}
	if includeUnresolved && !containsString(scopes, "unresolved") {
		scopes = append(scopes, "unresolved")
	}
	return scopes
}

func configuredWorkerReviewDispositionSlotScopes() []string {
	config := map[string]any{}
	if err := readJSONFile(workerLauncherConfigPath(), &config); err != nil {
		return nil
	}
	executor, ok := config["executor"].(map[string]any)
	if !ok {
		return nil
	}
	rawScopes, ok := executor["review_disposition_slot_scopes"].([]any)
	if !ok {
		return nil
	}
	scopes := []string{}
	for _, rawScope := range rawScopes {
		scope := stringValue(rawScope)
		if scope != "" && !containsString(scopes, scope) {
			scopes = append(scopes, scope)
		}
	}
	return scopes
}

func validateWorkerReviewDispositionSlotScopes(value any) []string {
	scopes := stringSliceValue(value)
	if len(scopes) == 0 {
		return []string{"review_disposition.slot_scopes must be a non-empty array of strings"}
	}
	return nil
}

func stringSliceValue(value any) []string {
	raw, ok := value.([]any)
	if !ok {
		if typed, ok := value.([]string); ok {
			return typed
		}
		return nil
	}
	values := []string{}
	for _, entry := range raw {
		scope := stringValue(entry)
		if strings.TrimSpace(scope) == "" {
			return nil
		}
		values = append(values, scope)
	}
	return values
}

func invalidStringMembers(values []string, valid []string) []string {
	invalid := []string{}
	for _, value := range values {
		if !containsString(valid, value) {
			invalid = append(invalid, value)
		}
	}
	return invalid
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func sortedKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
