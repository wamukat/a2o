package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWorkerScaffoldWritesRunnablePythonWorkerAndValidateResult(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "worker.py")
	resultPath := filepath.Join(tempDir, "result.json")
	requestPath := filepath.Join(tempDir, "request.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"python",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_scaffold_written path="+workerPath+" language=python") {
		t.Fatalf("stdout should describe scaffold path, got %q", stdout.String())
	}
	info, err := os.Stat(workerPath)
	if err != nil {
		t.Fatalf("worker scaffold missing: %v", err)
	}
	if info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("worker scaffold should be executable, mode=%s", info.Mode())
	}

	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	requestBody, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, append(requestBody, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("python3", workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated worker failed: %v\n%s", err, string(output))
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{
		"worker",
		"validate-result",
		"--request",
		requestPath,
		"--result",
		resultPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_protocol_status=ok") {
		t.Fatalf("validate-result should report ok, got %q", stdout.String())
	}
}

func TestWorkerScaffoldBashIsSelfContained(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "worker.sh")
	resultPath := filepath.Join(tempDir, "result.json")
	requestPath := filepath.Join(tempDir, "request.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"bash",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if strings.Contains(readFileString(t, workerPath), "python") {
		t.Fatalf("bash scaffold should not depend on python:\n%s", readFileString(t, workerPath))
	}
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-bash",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	writeJSONFileForTest(t, requestPath, request)
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated bash worker failed: %v\n%s", err, string(output))
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
}

func TestWorkerScaffoldGoPrintsGoRunCommandAndValidates(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "worker.go")
	resultPath := filepath.Join(tempDir, "result.json")
	requestPath := filepath.Join(tempDir, "request.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"go",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_scaffold_command=go run "+workerPath+" --schema {{schema_path}} --result {{result_path}}") {
		t.Fatalf("go scaffold should print go run command, got %q", stdout.String())
	}
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-go",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	writeJSONFileForTest(t, requestPath, request)
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("go", "run", workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated go worker failed: %v\n%s", err, string(output))
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
}

func TestWorkerScaffoldCommandWrapsConfiguredCommandAndValidates(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "a2o-command-worker")
	fakeWorkerPath := filepath.Join(tempDir, "fake-worker.py")
	resultPath := filepath.Join(tempDir, "result.json")
	requestPath := filepath.Join(tempDir, "request.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"command",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_scaffold_written path="+workerPath+" language=command") {
		t.Fatalf("stdout should describe command scaffold, got %q", stdout.String())
	}
	if !strings.Contains(readFileString(t, workerPath), "A2O_WORKER_COMMAND") {
		t.Fatalf("command scaffold should document A2O_WORKER_COMMAND:\n%s", readFileString(t, workerPath))
	}

	fakeWorker := `#!/usr/bin/env python3
import json
import sys

bundle = json.load(sys.stdin)
request = bundle["request"]
repo_scope = next(iter(request["slot_paths"]))
json.dump({
    "task_ref": request["task_ref"],
    "run_ref": request["run_ref"],
    "phase": request["phase"],
    "success": True,
    "summary": "worker implemented",
    "failing_command": None,
    "observed_state": None,
    "rework_required": False,
    "changed_files": {},
    "review_disposition": {
        "kind": "completed",
        "slot_scopes": [repo_scope],
        "summary": "worker self-review clean",
        "description": "The command wrapper preserved the A2O response contract.",
        "finding_key": "completed-no-findings"
    }
}, sys.stdout)
`
	if err := os.WriteFile(fakeWorkerPath, []byte(fakeWorker), 0o755); err != nil {
		t.Fatal(err)
	}
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-command",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	writeJSONFileForTest(t, requestPath, request)
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Env = append(os.Environ(), "A2O_WORKER_COMMAND="+fakeWorkerPath)
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated command worker failed: %v\n%s", err, string(output))
	}

	stdout.Reset()
	stderr.Reset()
	code = run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_protocol_status=ok") {
		t.Fatalf("validate-result should report ok, got %q", stdout.String())
	}
}

func TestWorkerScaffoldCommandWritesFailureWhenCommandCannotLaunch(t *testing.T) {
	tempDir := t.TempDir()
	workerPath := filepath.Join(tempDir, "a2o-command-worker")
	resultPath := filepath.Join(tempDir, "result.json")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{
		"worker",
		"scaffold",
		"--language",
		"command",
		"--output",
		workerPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
	}
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-command-missing",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	bundleBody, err := json.Marshal(map[string]any{"request": request})
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(workerPath, "--schema", filepath.Join(tempDir, "schema.json"), "--result", resultPath)
	cmd.Env = append(os.Environ(), "A2O_WORKER_COMMAND="+filepath.Join(tempDir, "missing-worker"))
	cmd.Stdin = bytes.NewReader(bundleBody)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("generated command worker should write structured failure and exit 0: %v\n%s", err, string(output))
	}
	result := map[string]any{}
	readJSONFileForTest(t, resultPath, &result)
	if result["success"] != false || result["observed_state"] != "worker_command_launch_failed" {
		t.Fatalf("unexpected structured failure: %#v", result)
	}
}

func TestWorkerValidateResultReportsConcreteProtocolErrors(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := []byte(`{"task_ref":"A2O#62","run_ref":"run-1","phase":"implementation"}`)
	result := []byte(`{"task_ref":"A2O#62","run_ref":"run-1","phase":"review","success":"yes","rework_required":false}`)
	if err := os.WriteFile(requestPath, append(request, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(resultPath, append(result, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{
		"worker",
		"validate-result",
		"--request",
		requestPath,
		"--result",
		resultPath,
	}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	for _, want := range []string{
		"worker_protocol_check name=result_schema status=blocked",
		"worker_protocol_error=summary must be present",
		"worker_protocol_error=phase must match the worker request",
		"worker_protocol_error=success must be true or false",
		"worker_protocol_status=blocked",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("validate-result output missing %q in:\n%s", want, stdout.String())
		}
	}
	if !strings.Contains(stderr.String(), "error_category=configuration_error") {
		t.Fatalf("stderr should classify protocol error, got %q", stderr.String())
	}
}

func TestWorkerValidateResultRequiresReviewDispositionForImplementationSuccess(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	result := map[string]any{
		"task_ref":        "A2O#62",
		"run_ref":         "run-1",
		"phase":           "implementation",
		"success":         true,
		"summary":         "implemented",
		"failing_command": nil,
		"observed_state":  nil,
		"rework_required": false,
		"changed_files":   map[string]any{},
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	if !strings.Contains(stdout.String(), "worker_protocol_error=review_disposition must be present for implementation success") {
		t.Fatalf("validate-result output missing review_disposition error in:\n%s", stdout.String())
	}
}

func TestWorkerValidateResultAcceptsClarificationRequestWithoutFailureDiagnostics(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref": "A2O#62",
		"run_ref":  "run-1",
		"phase":    "review",
	}
	result := map[string]any{
		"task_ref":        "A2O#62",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         false,
		"summary":         "requirement conflict",
		"rework_required": false,
		"clarification_request": map[string]any{
			"question":           "Which behavior should win?",
			"context":            "The request conflicts with the permission model.",
			"options":            []any{"Change permissions", "Keep current behavior"},
			"recommended_option": "Keep current behavior",
			"impact":             "The task waits for requester input.",
		},
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_protocol_status=ok") {
		t.Fatalf("validate-result should report ok, got %q", stdout.String())
	}
}

func TestWorkerValidateResultAcceptsParentReviewClarificationWithoutReviewDisposition(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref": "A2O#62",
		"run_ref":  "run-1",
		"phase":    "review",
		"phase_runtime": map[string]any{
			"task_kind": "parent",
		},
	}
	result := map[string]any{
		"task_ref":        "A2O#62",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         false,
		"summary":         "parent review needs requester input",
		"rework_required": false,
		"clarification_request": map[string]any{
			"question": "Which child boundary should be used?",
			"context":  "Both decompositions are plausible.",
		},
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_protocol_status=ok") {
		t.Fatalf("validate-result should report ok, got %q", stdout.String())
	}
}

func TestWorkerValidateResultRejectsMalformedReviewDispositionOnImplementationFailure(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	result := map[string]any{
		"task_ref":           "A2O#62",
		"run_ref":            "run-1",
		"phase":              "implementation",
		"success":            false,
		"summary":            "implementation failed",
		"failing_command":    "worker",
		"observed_state":     "failed",
		"rework_required":    false,
		"review_disposition": "not-an-object",
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	if !strings.Contains(stdout.String(), "worker_protocol_error=review_disposition must be an object") {
		t.Fatalf("validate-result output missing review_disposition shape error in:\n%s", stdout.String())
	}
}

func TestWorkerValidateResultRejectsRuntimeProtocolShapeMismatches(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	result := map[string]any{
		"task_ref":        "A2O#62",
		"run_ref":         "run-1",
		"phase":           "implementation",
		"success":         true,
		"summary":         "bad shape",
		"failing_command": 123,
		"observed_state":  true,
		"rework_required": false,
		"diagnostics":     "oops",
		"changed_files":   map[string]any{"app": "README.md"},
		"review_disposition": map[string]any{
			"kind":        "follow_up_child",
			"slot_scopes": []string{"all"},
			"repo_scope":  "app",
			"summary":     "bad disposition",
			"description": "bad disposition",
			"finding_key": "bad-disposition",
		},
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	for _, want := range []string{
		"worker_protocol_error=failing_command must be a string or null when success is true",
		"worker_protocol_error=observed_state must be a string or null when success is true",
		"worker_protocol_error=diagnostics must be an object",
		"worker_protocol_error=changed_files for app must be an array of strings",
		"worker_protocol_error=review_disposition.repo_scope is not supported; use review_disposition.slot_scopes",
		"worker_protocol_error=review_disposition.kind must be completed for implementation evidence",
		"worker_protocol_error=review_disposition.slot_scopes must be one of app",
	} {
		if !strings.Contains(stdout.String(), want) {
			t.Fatalf("validate-result output missing %q in:\n%s", want, stdout.String())
		}
	}
}

func TestWorkerValidateResultRejectsNullableImplementationReviewEvidence(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref":   "A2O#62",
		"run_ref":    "run-1",
		"phase":      "implementation",
		"slot_paths": map[string]any{"app": filepath.Join(tempDir, "app")},
	}
	result := map[string]any{
		"task_ref":           "A2O#62",
		"run_ref":            "run-1",
		"phase":              "implementation",
		"success":            true,
		"summary":            "no changes",
		"failing_command":    nil,
		"observed_state":     nil,
		"rework_required":    false,
		"changed_files":      nil,
		"review_disposition": nil,
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail")
	}
	if !strings.Contains(stdout.String(), "worker_protocol_error=review_disposition must be present for implementation success") {
		t.Fatalf("validate-result output missing review_disposition error in:\n%s", stdout.String())
	}
}

func TestWorkerValidateResultMatchesRuntimeEmptyStringSemantics(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref": "A2O#62",
		"run_ref":  "run-1",
		"phase":    "review",
	}
	result := map[string]any{
		"task_ref":        "",
		"run_ref":         "run-1",
		"phase":           "review",
		"success":         false,
		"summary":         "review finding",
		"failing_command": "",
		"observed_state":  "",
		"rework_required": false,
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{"worker", "validate-result", "--request", requestPath, "--result", resultPath}, &fakeRunner{}, &stdout, &stderr)
	if code == 0 {
		t.Fatalf("validate-result should fail because task_ref does not match")
	}
	if !strings.Contains(stdout.String(), "worker_protocol_error=task_ref must match the worker request") {
		t.Fatalf("validate-result should report task_ref mismatch, got:\n%s", stdout.String())
	}
	if strings.Contains(stdout.String(), "failing_command must be a string") || strings.Contains(stdout.String(), "observed_state must be a string") {
		t.Fatalf("empty failing_command/observed_state strings should match runtime semantics, got:\n%s", stdout.String())
	}
}

func TestWorkerPublicValidatorMatchesSharedProtocolFixtures(t *testing.T) {
	for _, tc := range loadSharedWorkerProtocolCases(t) {
		t.Run(tc.Name, func(t *testing.T) {
			errors := validatePublicWorkerPayload(tc.Result, tc.Request, workerValidationOptions{})
			if tc.Valid {
				if len(errors) != 0 {
					t.Fatalf("expected valid shared protocol fixture, got %#v", errors)
				}
				return
			}
			for _, expected := range tc.ExpectedErrors {
				if !containsString(errors, expected) {
					t.Fatalf("expected %q in %#v", expected, errors)
				}
			}
		})
	}
}

func TestWorkerValidateResultHonorsConfiguredReviewSlotScopes(t *testing.T) {
	tempDir := t.TempDir()
	requestPath := filepath.Join(tempDir, "request.json")
	resultPath := filepath.Join(tempDir, "result.json")
	request := map[string]any{
		"task_ref": "A2O#62",
		"run_ref":  "run-1",
		"phase":    "implementation",
	}
	result := map[string]any{
		"task_ref":        "A2O#62",
		"run_ref":         "run-1",
		"phase":           "implementation",
		"success":         true,
		"summary":         "configured scope",
		"failing_command": nil,
		"observed_state":  nil,
		"rework_required": false,
		"changed_files":   map[string]any{},
		"review_disposition": map[string]any{
			"kind":        "completed",
			"slot_scopes": []string{"package"},
			"summary":     "configured scope",
			"description": "configured scope",
			"finding_key": "",
		},
	}
	writeJSONFileForTest(t, requestPath, request)
	writeJSONFileForTest(t, resultPath, result)

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run([]string{
		"worker",
		"validate-result",
		"--request",
		requestPath,
		"--result",
		resultPath,
		"--review-slot-scope",
		"package",
	}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("validate-result returned %d, stdout=%s stderr=%s", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "worker_protocol_status=ok") {
		t.Fatalf("validate-result should report ok, got %q", stdout.String())
	}
}

func TestTopLevelUsageDocumentsReviewSlotScope(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	code := run([]string{"--help"}, &fakeRunner{}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("help returned %d, stderr=%s", code, stderr.String())
	}
	usage := stdout.String()
	if !strings.Contains(usage, "--review-slot-scope SCOPE") {
		t.Fatalf("usage should document --review-slot-scope, got %q", usage)
	}
	if strings.Contains(usage, "--review-scope") || strings.Contains(usage, "--repo-scope-alias") {
		t.Fatalf("usage should not document removed review disposition flags, got %q", usage)
	}
}

func writeJSONFileForTest(t *testing.T, path string, payload any) {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(body, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readJSONFileForTest(t *testing.T, path string, target any) {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, target); err != nil {
		t.Fatal(err)
	}
}

type sharedWorkerProtocolCase struct {
	Name           string         `json:"name"`
	Valid          bool           `json:"valid"`
	ExpectedErrors []string       `json:"expected_errors"`
	Request        map[string]any `json:"request"`
	Result         map[string]any `json:"result"`
}

func loadSharedWorkerProtocolCases(t *testing.T) []sharedWorkerProtocolCase {
	t.Helper()
	path := filepath.Join("..", "..", "..", "test", "fixtures", "worker_protocol", "cases.json")
	var cases []sharedWorkerProtocolCase
	readJSONFileForTest(t, path, &cases)
	return cases
}
