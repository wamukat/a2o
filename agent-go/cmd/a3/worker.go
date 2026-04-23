package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

func runWorker(args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "missing worker subcommand")
		printUsage(stderr)
		return 2
	}
	if isHelpArg(args[0]) {
		printUsage(stdout)
		return 0
	}
	switch args[0] {
	case "scaffold":
		if err := runWorkerScaffold(args[1:], stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	case "validate-result":
		if err := runWorkerValidateResult(args[1:], stdout, stderr); err != nil {
			printUserFacingError(stderr, err)
			return 1
		}
		return 0
	default:
		fmt.Fprintf(stderr, "unknown worker subcommand: %s\n", args[0])
		printUsage(stderr)
		return 2
	}
}

func runWorkerScaffold(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o worker scaffold", flag.ContinueOnError)
	flags.SetOutput(stderr)

	language := flags.String("language", "python", "worker language: bash, python, ruby, go, copilot")
	outputPath := flags.String("output", "", "worker file path to write")
	force := flags.Bool("force", false, "overwrite an existing worker file")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if strings.TrimSpace(*outputPath) == "" {
		return fmt.Errorf("--output is required")
	}
	body, mode, err := workerScaffoldTemplate(*language)
	if err != nil {
		return err
	}
	if !*force {
		if _, err := os.Stat(*outputPath); err == nil {
			return fmt.Errorf("worker scaffold already exists: %s; pass --force to overwrite", *outputPath)
		} else if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("inspect worker scaffold: %w", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(*outputPath), 0o755); err != nil {
		return fmt.Errorf("create worker scaffold directory: %w", err)
	}
	if err := os.WriteFile(*outputPath, []byte(body), mode); err != nil {
		return fmt.Errorf("write worker scaffold: %w", err)
	}
	normalizedLanguage := normalizeWorkerLanguage(*language)
	fmt.Fprintf(stdout, "worker_scaffold_written path=%s language=%s\n", *outputPath, normalizedLanguage)
	fmt.Fprintf(stdout, "worker_scaffold_command=%s\n", workerScaffoldCommand(normalizedLanguage, *outputPath))
	return nil
}

func runWorkerValidateResult(args []string, stdout io.Writer, stderr io.Writer) error {
	flags := flag.NewFlagSet("a2o worker validate-result", flag.ContinueOnError)
	flags.SetOutput(stderr)

	requestPath := flags.String("request", "", "worker request JSON path")
	resultPath := flags.String("result", "", "worker result JSON path")
	var reviewScopes stringListFlag
	var repoScopeAliases stringListFlag
	flags.Var(&reviewScopes, "review-scope", "valid review_disposition repo_scope; repeat to match executor configuration")
	flags.Var(&repoScopeAliases, "repo-scope-alias", "review_disposition repo_scope alias in from=to form; repeat to match executor configuration")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(flags.Args(), " "))
	}
	if strings.TrimSpace(*requestPath) == "" {
		return fmt.Errorf("--request is required")
	}
	if strings.TrimSpace(*resultPath) == "" {
		return fmt.Errorf("--result is required")
	}
	request := map[string]any{}
	if err := readWorkerJSONFile(*requestPath, &request); err != nil {
		return fmt.Errorf("read worker request: %w", err)
	}
	result := map[string]any{}
	if err := readWorkerJSONFile(*resultPath, &result); err != nil {
		return fmt.Errorf("read worker result: %w", err)
	}
	aliases, err := parseWorkerRepoScopeAliases(repoScopeAliases)
	if err != nil {
		return err
	}
	errors := validatePublicWorkerPayload(result, request, workerValidationOptions{
		ReviewScopes:     reviewScopes,
		RepoScopeAliases: aliases,
	})
	if len(errors) == 0 {
		fmt.Fprintln(stdout, "worker_protocol_check name=result_schema status=ok")
		fmt.Fprintln(stdout, "worker_protocol_status=ok")
		return nil
	}
	fmt.Fprintln(stdout, "worker_protocol_check name=result_schema status=blocked")
	for _, validationError := range errors {
		fmt.Fprintf(stdout, "worker_protocol_error=%s\n", validationError)
	}
	fmt.Fprintln(stdout, "worker_protocol_status=blocked")
	return fmt.Errorf("worker result protocol invalid; fix the reported worker_protocol_error entries")
}

func readWorkerJSONFile(path string, target any) error {
	body, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(body, target); err != nil {
		return err
	}
	return nil
}

type workerValidationOptions struct {
	ReviewScopes     []string
	RepoScopeAliases map[string]string
}

func workerScaffoldTemplate(language string) (string, os.FileMode, error) {
	switch normalizeWorkerLanguage(language) {
	case "bash":
		return bashWorkerScaffold, 0o755, nil
	case "python":
		return pythonWorkerScaffold, 0o755, nil
	case "ruby":
		return rubyWorkerScaffold, 0o755, nil
	case "go":
		return goWorkerScaffold, 0o644, nil
	case "copilot":
		return copilotWorkerScaffold, 0o755, nil
	default:
		return "", 0, fmt.Errorf("--language must be one of bash, python, ruby, go, copilot")
	}
}

func workerScaffoldCommand(language string, outputPath string) string {
	if language == "go" {
		return "go run " + outputPath + " --schema {{schema_path}} --result {{result_path}}"
	}
	return outputPath + " --schema {{schema_path}} --result {{result_path}}"
}

func normalizeWorkerLanguage(language string) string {
	switch strings.ToLower(strings.TrimSpace(language)) {
	case "sh", "shell":
		return "bash"
	case "py", "python3":
		return "python"
	case "golang":
		return "go"
	case "github-copilot", "gh-copilot":
		return "copilot"
	default:
		return strings.ToLower(strings.TrimSpace(language))
	}
}

func validatePublicWorkerPayload(payload map[string]any, request map[string]any, options workerValidationOptions) []string {
	errors := []string{}
	for _, key := range publicWorkerRequiredFields(request) {
		if _, ok := payload[key]; !ok {
			errors = append(errors, key+" must be present")
		}
	}
	if value, ok := payload["task_ref"]; ok && value != request["task_ref"] {
		errors = append(errors, "task_ref must match the worker request")
	}
	if value, ok := payload["run_ref"]; ok && value != request["run_ref"] {
		errors = append(errors, "run_ref must match the worker request")
	}
	if value, ok := payload["phase"]; ok && value != request["phase"] {
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
		if rework, _ := payload["rework_required"].(bool); !rework {
			if _, ok := payload["failing_command"].(string); !ok {
				errors = append(errors, "failing_command must be a string when success is false unless rework_required is true")
			}
		}
		if _, ok := payload["observed_state"].(string); !ok {
			errors = append(errors, "observed_state must be a string when success is false")
		}
	} else {
		if value, ok := payload["failing_command"]; ok && value != nil {
			if _, ok := value.(string); !ok {
				errors = append(errors, "failing_command must be a string or null when success is true")
			}
		}
		if value, ok := payload["observed_state"]; ok && value != nil {
			if _, ok := value.(string); !ok {
				errors = append(errors, "observed_state must be a string or null when success is true")
			}
		}
	}
	if diagnostics, ok := payload["diagnostics"]; ok && diagnostics != nil {
		if _, ok := diagnostics.(map[string]any); !ok {
			errors = append(errors, "diagnostics must be an object")
		}
	}
	if workerStringValue(request["phase"]) == "implementation" && success {
		changedFiles, ok := payload["changed_files"]
		if !ok {
			errors = append(errors, "changed_files must be present for implementation success")
		} else if changedFiles != nil {
			changedFilesMap, ok := changedFiles.(map[string]any)
			if !ok {
				errors = append(errors, "changed_files must be an object when present")
			} else {
				errors = append(errors, validateChangedFiles(changedFilesMap)...)
			}
		}
	} else if changedFiles, ok := payload["changed_files"]; ok && changedFiles != nil {
		changedFilesMap, ok := changedFiles.(map[string]any)
		if !ok {
			errors = append(errors, "changed_files must be an object when present")
		} else {
			errors = append(errors, validateChangedFiles(changedFilesMap)...)
		}
	}
	if publicWorkerNeedsReviewDisposition(request, success) || payload["review_disposition"] != nil {
		rawDisposition, ok := payload["review_disposition"]
		if !ok {
			if workerStringValue(request["phase"]) == "implementation" {
				errors = append(errors, "review_disposition must be present for implementation success")
			} else {
				errors = append(errors, "review_disposition must be present for parent review")
			}
		} else if workerStringValue(request["phase"]) == "implementation" && rawDisposition == nil {
			errors = append(errors, "review_disposition must be present for implementation success")
			return errors
		} else {
			disposition, ok := rawDisposition.(map[string]any)
			if !ok {
				errors = append(errors, "review_disposition must be an object")
				return errors
			}
			for _, key := range []string{"kind", "repo_scope", "summary", "description", "finding_key"} {
				if _, ok := disposition[key].(string); !ok {
					errors = append(errors, "review_disposition."+key+" must be a string")
				}
			}
			errors = append(errors, validateReviewDisposition(disposition, request, options)...)
		}
	}
	return errors
}

func parseWorkerRepoScopeAliases(values []string) (map[string]string, error) {
	aliases := map[string]string{}
	for _, value := range values {
		left, right, ok := strings.Cut(value, "=")
		left = strings.TrimSpace(left)
		right = strings.TrimSpace(right)
		if !ok || left == "" || right == "" {
			return nil, fmt.Errorf("--repo-scope-alias must use from=to with non-empty values")
		}
		aliases[left] = right
	}
	return aliases, nil
}

func validateChangedFiles(changedFiles map[string]any) []string {
	errors := []string{}
	for slotName, files := range changedFiles {
		if slotName == "" {
			errors = append(errors, "changed_files slot names must be strings")
		}
		fileList, ok := files.([]any)
		if !ok {
			errors = append(errors, "changed_files for "+slotName+" must be an array of strings")
			continue
		}
		for _, entry := range fileList {
			if _, ok := entry.(string); !ok {
				errors = append(errors, "changed_files for "+slotName+" must be an array of strings")
				break
			}
		}
	}
	return errors
}

func validateReviewDisposition(disposition map[string]any, request map[string]any, options workerValidationOptions) []string {
	phase := workerStringValue(request["phase"])
	parentReview := phase == "review" && workerNestedString(request, "phase_runtime", "task_kind") == "parent"
	validScopes := validReviewDispositionRepoScopes(request, parentReview, options)
	repoScope := workerStringValue(disposition["repo_scope"])
	if replacement := options.RepoScopeAliases[repoScope]; replacement != "" {
		repoScope = replacement
	}
	errors := []string{}
	if parentReview {
		if !containsString([]string{"completed", "follow_up_child", "blocked"}, workerStringValue(disposition["kind"])) {
			errors = append(errors, "review_disposition.kind must be one of completed, follow_up_child, blocked")
		}
		if !containsString(validScopes, repoScope) {
			errors = append(errors, "review_disposition.repo_scope must be one of "+strings.Join(validScopes, ", "))
		}
		return errors
	}
	if phase == "implementation" {
		if workerStringValue(disposition["kind"]) != "completed" {
			errors = append(errors, "review_disposition.kind must be completed for implementation evidence")
		}
		if !containsString(validScopes, repoScope) {
			errors = append(errors, "review_disposition.repo_scope must be one of "+strings.Join(validScopes, ", "))
		}
	}
	return errors
}

func validReviewDispositionRepoScopes(request map[string]any, includeUnresolved bool, options workerValidationOptions) []string {
	scopes := []string{}
	if len(options.ReviewScopes) > 0 {
		for _, scope := range options.ReviewScopes {
			if scope != "" && !containsString(scopes, scope) {
				scopes = append(scopes, scope)
			}
		}
	} else if slotPaths, ok := request["slot_paths"].(map[string]any); ok {
		for slotName := range slotPaths {
			if slotName != "" && !containsString(scopes, slotName) {
				scopes = append(scopes, slotName)
			}
		}
	}
	if includeUnresolved && !containsString(scopes, "unresolved") {
		scopes = append(scopes, "unresolved")
	}
	return scopes
}

func publicWorkerRequiredFields(request map[string]any) []string {
	fields := []string{"task_ref", "run_ref", "phase", "success", "summary", "failing_command", "observed_state", "rework_required"}
	phase := workerStringValue(request["phase"])
	if phase == "review" && workerNestedString(request, "phase_runtime", "task_kind") == "parent" {
		fields = append(fields, "review_disposition")
	}
	return fields
}

func publicWorkerNeedsReviewDisposition(request map[string]any, success bool) bool {
	phase := workerStringValue(request["phase"])
	return (phase == "implementation" && success) || (phase == "review" && workerNestedString(request, "phase_runtime", "task_kind") == "parent")
}

func workerStringValue(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}

func workerNestedString(value map[string]any, keys ...string) string {
	var current any = value
	for _, key := range keys {
		currentMap, ok := current.(map[string]any)
		if !ok {
			return ""
		}
		current = currentMap[key]
	}
	return workerStringValue(current)
}

const pythonWorkerScaffold = `#!/usr/bin/env python3
import argparse
import json
import sys


def request_from_stdin():
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        payload = {}
    request = payload.get("request", payload)
    return request if isinstance(request, dict) else {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=False)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()
    request = request_from_stdin()
    repo_scope = next(iter(request.get("slot_paths", {"app": ""})), "app")
    result = {
        "task_ref": request.get("task_ref", ""),
        "run_ref": request.get("run_ref", ""),
        "phase": request.get("phase", ""),
        "success": True,
        "summary": "scaffold worker completed without changes",
        "failing_command": None,
        "observed_state": None,
        "rework_required": False,
        "changed_files": {},
        "review_disposition": {
            "kind": "completed",
            "repo_scope": repo_scope,
            "summary": "scaffold worker self-review clean",
            "description": "No changes were required by the scaffold worker.",
            "finding_key": "none",
        },
    }
    with open(args.result, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
`

const copilotWorkerScaffold = `#!/usr/bin/env python3
"""A2O Copilot worker wrapper scaffold.

Configure A2O_COPILOT_COMMAND to a command that reads the A2O stdin bundle
from stdin and prints the final A2O worker result JSON to stdout.

Example:
  export A2O_COPILOT_COMMAND='your-copilot-wrapper --json'
"""

import argparse
import json
import os
import shlex
import subprocess
import sys


def load_bundle():
    raw = sys.stdin.read()
    try:
        parsed = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        parsed = {}
    request = parsed.get("request", parsed) if isinstance(parsed, dict) else {}
    if not isinstance(request, dict):
        request = {}
    return raw, request


def failure(request, summary, command, observed_state, diagnostics=None):
    return {
        "task_ref": request.get("task_ref", ""),
        "run_ref": request.get("run_ref", ""),
        "phase": request.get("phase", ""),
        "success": False,
        "summary": summary,
        "failing_command": command,
        "observed_state": observed_state,
        "rework_required": False,
        "diagnostics": diagnostics or {},
    }


def write_result(path, payload):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def validate_contract(request, payload):
    if not isinstance(payload, dict):
        return "copilot worker output must be a JSON object"
    if payload.get("success") is True and request.get("phase") == "implementation":
        if "review_disposition" not in payload or payload.get("review_disposition") is None:
            return "review_disposition must be present for implementation success"
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=False)
    parser.add_argument("--result", required=True)
    args = parser.parse_args()

    bundle_raw, request = load_bundle()
    command_text = os.environ.get("A2O_COPILOT_COMMAND", "").strip()
    if not command_text:
        write_result(
            args.result,
            failure(
                request,
                "copilot worker command is not configured",
                "A2O_COPILOT_COMMAND",
                "missing_copilot_command",
                {
                    "expected": "Set A2O_COPILOT_COMMAND to a command that prints A2O worker result JSON.",
                    "schema_path": args.schema,
                },
            ),
        )
        return

    command = []
    try:
        command = shlex.split(command_text)
        completed = subprocess.run(
            command,
            input=bundle_raw,
            text=True,
            capture_output=True,
            check=False,
        )
    except (OSError, ValueError) as exc:
        write_result(
            args.result,
            failure(
                request,
                "copilot worker command could not be launched",
                command[0] if command else "A2O_COPILOT_COMMAND",
                "copilot_command_launch_failed",
                {"error": f"{type(exc).__name__}: {exc}"},
            ),
        )
        return
    if completed.returncode != 0:
        write_result(
            args.result,
            failure(
                request,
                "copilot worker command failed",
                command[0],
                f"exit {completed.returncode}",
                {"stderr": completed.stderr[-4000:], "stdout": completed.stdout[-4000:]},
            ),
        )
        return

    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError:
        write_result(
            args.result,
            failure(
                request,
                "copilot worker output was not valid JSON",
                command[0],
                "invalid_copilot_json",
                {"stdout": completed.stdout[-4000:], "stderr": completed.stderr[-4000:]},
            ),
        )
        return

    contract_error = validate_contract(request, payload)
    if contract_error:
        write_result(
            args.result,
            failure(
                request,
                "copilot worker result contract invalid",
                command[0],
                "invalid_copilot_result",
                {"validation_errors": [contract_error]},
            ),
        )
        return

    write_result(args.result, payload)


if __name__ == "__main__":
    main()
`

const rubyWorkerScaffold = `#!/usr/bin/env ruby
require "json"
require "optparse"

options = {}
OptionParser.new do |parser|
  parser.on("--schema PATH") { |value| options[:schema] = value }
  parser.on("--result PATH") { |value| options[:result] = value }
end.parse!
raise "--result is required" if options[:result].to_s.strip.empty?

payload = begin
  JSON.parse(STDIN.read)
rescue JSON::ParserError
  {}
end
request = payload.fetch("request", payload)
request = {} unless request.is_a?(Hash)
slot_paths = request.fetch("slot_paths", { "app" => "" })
repo_scope = slot_paths.is_a?(Hash) && !slot_paths.empty? ? slot_paths.keys.first.to_s : "app"

result = {
  "task_ref" => request.fetch("task_ref", ""),
  "run_ref" => request.fetch("run_ref", ""),
  "phase" => request.fetch("phase", ""),
  "success" => true,
  "summary" => "scaffold worker completed without changes",
  "failing_command" => nil,
  "observed_state" => nil,
  "rework_required" => false,
  "changed_files" => {},
  "review_disposition" => {
    "kind" => "completed",
    "repo_scope" => repo_scope,
    "summary" => "scaffold worker self-review clean",
    "description" => "No changes were required by the scaffold worker.",
    "finding_key" => "none"
  }
}

File.write(options[:result], JSON.pretty_generate(result) + "\n")
`

const bashWorkerScaffold = `#!/usr/bin/env bash
set -euo pipefail

result_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --schema)
      shift 2
      ;;
    --result)
      result_path="${2:-}"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$result_path" ]]; then
  echo "--result is required" >&2
  exit 2
fi

bundle_path="$(mktemp)"
trap 'rm -f "$bundle_path"' EXIT
cat > "$bundle_path"

extract_json_string() {
  local key="$1"
  sed -n "s/.*\\\"${key}\\\"[[:space:]]*:[[:space:]]*\\\"\\([^\\\"]*\\)\\\".*/\\1/p" "$bundle_path" | head -n 1
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

task_ref="$(extract_json_string task_ref)"
run_ref="$(extract_json_string run_ref)"
phase="$(extract_json_string phase)"
repo_scope="$(
  awk '
    /"slot_paths"[[:space:]]*:[[:space:]]*\{/ { in_slot_paths=1; next }
    in_slot_paths && /}/ { exit }
    in_slot_paths && match($0, /"[^"]+"[[:space:]]*:/) {
      value=substr($0, RSTART + 1, RLENGTH - 3)
      print value
      exit
    }
  ' "$bundle_path"
)"
if [[ -z "$repo_scope" ]]; then
  repo_scope="app"
fi

cat > "$result_path" <<JSON
{
  "task_ref": "$(json_escape "$task_ref")",
  "run_ref": "$(json_escape "$run_ref")",
  "phase": "$(json_escape "$phase")",
  "success": true,
  "summary": "scaffold worker completed without changes",
  "failing_command": null,
  "observed_state": null,
  "rework_required": false,
  "changed_files": {},
  "review_disposition": {
    "kind": "completed",
    "repo_scope": "$(json_escape "$repo_scope")",
    "summary": "scaffold worker self-review clean",
    "description": "No changes were required by the scaffold worker.",
    "finding_key": "none"
  }
}
JSON
`

const goWorkerScaffold = `package main

import (
	"encoding/json"
	"flag"
	"os"
)

func main() {
	schemaPath := flag.String("schema", "", "worker response schema path")
	resultPath := flag.String("result", "", "worker result path")
	flag.Parse()
	_ = schemaPath
	if *resultPath == "" {
		panic("--result is required")
	}

	payload := map[string]any{}
	_ = json.NewDecoder(os.Stdin).Decode(&payload)
	request, ok := payload["request"].(map[string]any)
	if !ok {
		request = payload
	}
	repoScope := "app"
	if slotPaths, ok := request["slot_paths"].(map[string]any); ok {
		for slotName := range slotPaths {
			if slotName != "" {
				repoScope = slotName
				break
			}
		}
	}

	result := map[string]any{
		"task_ref":         stringValue(request["task_ref"]),
		"run_ref":          stringValue(request["run_ref"]),
		"phase":            stringValue(request["phase"]),
		"success":          true,
		"summary":          "scaffold worker completed without changes",
		"failing_command":  nil,
		"observed_state":   nil,
		"rework_required":  false,
		"changed_files":    map[string]any{},
		"review_disposition": map[string]any{
			"kind":        "completed",
			"repo_scope":  repoScope,
			"summary":     "scaffold worker self-review clean",
			"description": "No changes were required by the scaffold worker.",
			"finding_key": "none",
		},
	}
	file, err := os.Create(*resultPath)
	if err != nil {
		panic(err)
	}
	defer file.Close()
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		panic(err)
	}
}

func stringValue(value any) string {
	text, _ := value.(string)
	return text
}
`
