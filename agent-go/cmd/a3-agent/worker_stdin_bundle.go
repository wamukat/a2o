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
)

type executorProfile struct {
	Command []string
	Env     map[string]string
}

func envCompat(publicName string, legacyName string) string {
	if value := strings.TrimSpace(os.Getenv(publicName)); value != "" {
		return value
	}
	return strings.TrimSpace(os.Getenv(legacyName))
}

func runWorkerStdinBundle(args []string) int {
	if len(args) != 0 {
		fmt.Fprintf(os.Stderr, "unexpected arguments: %s\n", strings.Join(args, " "))
		return 2
	}
	requestPath := envCompat("A2O_WORKER_REQUEST_PATH", "A3_WORKER_REQUEST_PATH")
	resultPath := envCompat("A2O_WORKER_RESULT_PATH", "A3_WORKER_RESULT_PATH")
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
	stdout, stderr, exitCode, runErr := runWorkerExecutor(command, commandEnv, workerWorkspaceRoot())
	if (runErr != nil || exitCode != 0) && !fileExists(resultPath) {
		diagnostics := map[string]any{"stdout": stdout, "stderr": stderr}
		if runErr != nil {
			diagnostics["error"] = runErr.Error()
		}
		return writeWorkerFailureResult(resultPath, request, workerFailure(request, "stdin worker launcher failed", command, fmt.Sprintf("exit %d", exitCode), diagnostics))
	}

	payload := map[string]any{}
	if err := readJSONFile(resultPath, &payload); err != nil {
		if os.IsNotExist(err) {
			return writeWorkerFailureResult(resultPath, request, workerFailure(request, "stdin worker returned no final result", command, "missing_worker_result", map[string]any{"stdout": stdout, "stderr": stderr}))
		}
		return writeWorkerFailureResult(resultPath, request, workerFailure(request, "stdin worker returned invalid json", command, "invalid_worker_json", map[string]any{"stdout": stdout, "stderr": stderr, "error": err.Error()}))
	}
	normalizeReviewDisposition(payload)
	if validationErrors := validateWorkerPayload(payload, request); len(validationErrors) > 0 {
		return writeWorkerFailureResult(resultPath, request, workerFailure(request, "worker result schema invalid", command, "invalid_worker_result", map[string]any{
			"validation_errors":      validationErrors,
			"worker_response_bundle": payload,
			"stdout":                 stdout,
			"stderr":                 stderr,
		}))
	}
	if err := writeJSONFile(resultPath, payload); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	return 0
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
			"repo_scope":  "unresolved",
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
	if root := envCompat("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT"); root != "" {
		return root
	}
	wd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return wd
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
			"repo_scope":  map[string]any{"type": "string"},
			"summary":     map[string]any{"type": "string"},
			"description": map[string]any{"type": "string"},
			"finding_key": map[string]any{"type": "string"},
		},
		"required":             []string{"kind", "repo_scope", "summary", "description", "finding_key"},
		"additionalProperties": false,
	}
}

func workerRequiredFields(request map[string]any) []string {
	fields := []string{"task_ref", "run_ref", "phase", "success", "summary", "failing_command", "observed_state", "rework_required"}
	phase := stringValue(request["phase"])
	if phase == "review" && nestedString(request, "phase_runtime", "task_kind") == "parent" {
		fields = append(fields, "review_disposition")
	}
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
	return envCompat("A2O_WORKER_LAUNCHER_CONFIG_PATH", "A3_WORKER_LAUNCHER_CONFIG_PATH")
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
	if root := strings.TrimSpace(os.Getenv("A3_ROOT_DIR")); root != "" {
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

func runWorkerExecutor(command []string, commandEnv map[string]string, workspaceRoot string) (string, string, int, error) {
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
	cmd.Stdin = strings.NewReader(workerBundle())
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
	root := envCompat("A2O_AGENT_AI_RAW_LOG_ROOT", "A3_AGENT_AI_RAW_LOG_ROOT")
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

func workerBundle() string {
	request := map[string]any{}
	_ = readJSONFile(envCompat("A2O_WORKER_REQUEST_PATH", "A3_WORKER_REQUEST_PATH"), &request)
	bundle := map[string]any{
		"type":        "a2o-worker-stdin-bundle",
		"instruction": workerInstruction(request),
		"request":     request,
		"response_contract": map[string]any{
			"mode":          "json-object",
			"required_keys": workerRequiredFields(request),
			"notes": []string{
				"Return a single JSON object only.",
				"Always include task_ref, run_ref, phase, success, summary, failing_command, observed_state, and rework_required.",
				"Use null for failing_command and observed_state when success is true.",
				"For implementation success, include changed_files keyed by slot name with relative paths to publish.",
				"For implementation success, include review_disposition with kind=completed when self-review is clean.",
				"For review failures caused by findings, include rework_required=true.",
				"For parent review, include review_disposition with kind, repo_scope, summary, description, and finding_key.",
			},
		},
		"operating_contract": map[string]any{
			"workspace_root": envCompat("A2O_WORKSPACE_ROOT", "A3_WORKSPACE_ROOT"),
			"slot_paths":     mapValue(request["slot_paths"]),
			"phase_runtime":  mapValue(request["phase_runtime"]),
			"rules": []string{
				"Only inspect and modify files under slot_paths.",
				"Read request.task_packet.title and request.task_packet.description before planning work.",
				"Treat phase_runtime.verification_commands as runner-owned unless explicitly needed for the phase.",
			},
		},
	}
	body, _ := json.MarshalIndent(bundle, "", "  ")
	return string(body)
}

func workerRequestValue(key string) any {
	request := map[string]any{}
	if err := readJSONFile(envCompat("A2O_WORKER_REQUEST_PATH", "A3_WORKER_REQUEST_PATH"), &request); err != nil {
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
		return instruction + " For parent review, always include review_disposition. Use kind=completed when review is clean, kind=follow_up_child with a configured slot repo_scope for code follow-up, and kind=blocked with repo_scope unresolved when the finding should block the parent. Parent review must not rely on rework_required routing."
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
		if rework, _ := payload["rework_required"].(bool); !rework && stringValue(payload["failing_command"]) == "" {
			errors = append(errors, "failing_command must be a string when success is false unless rework_required is true")
		}
		if stringValue(payload["observed_state"]) == "" {
			errors = append(errors, "observed_state must be a string when success is false")
		}
	}
	if stringValue(request["phase"]) == "implementation" && success {
		if _, ok := payload["changed_files"].(map[string]any); !ok {
			errors = append(errors, "changed_files must be present for implementation success")
		}
	}
	if needsReviewDisposition(request, success) {
		disposition, ok := payload["review_disposition"].(map[string]any)
		if !ok {
			if stringValue(request["phase"]) == "implementation" {
				errors = append(errors, "review_disposition must be present for implementation success")
			} else {
				errors = append(errors, "review_disposition must be present for parent review")
			}
		} else {
			for _, key := range []string{"kind", "repo_scope", "summary", "description", "finding_key"} {
				if stringValue(disposition[key]) == "" {
					errors = append(errors, "review_disposition."+key+" must be a string")
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

func normalizeReviewDisposition(payload map[string]any) {
	disposition, ok := payload["review_disposition"].(map[string]any)
	if !ok {
		return
	}
	config := map[string]any{}
	if err := readJSONFile(workerLauncherConfigPath(), &config); err != nil {
		return
	}
	executor, ok := config["executor"].(map[string]any)
	if !ok {
		return
	}
	aliases, ok := executor["review_disposition_repo_scope_aliases"].(map[string]any)
	if !ok {
		return
	}
	scope := stringValue(disposition["repo_scope"])
	if replacement := stringValue(aliases[scope]); replacement != "" {
		disposition["repo_scope"] = replacement
	}
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
