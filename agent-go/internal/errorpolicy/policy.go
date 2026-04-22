package errorpolicy

import "strings"

func WorkerCategory(summary string, observedState string, phase string) string {
	text := strings.ToLower(strings.Join([]string{summary, observedState, phase}, " "))
	switch {
	case strings.Contains(text, "config"), strings.Contains(text, "schema"), strings.Contains(text, "project.yaml"), strings.Contains(text, "executor config"), strings.Contains(text, "invalid_executor_config"), strings.Contains(text, "launcher"):
		return "configuration_error"
	case strings.Contains(text, "slot ") && strings.Contains(text, "has changes"), strings.Contains(text, "changed files"), strings.Contains(text, "working tree is dirty"):
		return "workspace_dirty"
	case phase == "verification":
		return "verification_failed"
	case strings.Contains(text, "dirty"), strings.Contains(text, "has changes"), strings.Contains(text, "untracked"), strings.Contains(text, "working tree"):
		return "workspace_dirty"
	case strings.Contains(text, "merge conflict"), strings.Contains(text, "conflict marker"), strings.Contains(text, "unmerged"):
		return "merge_conflict"
	case phase == "merge":
		return "merge_failed"
	default:
		return "executor_failed"
	}
}

func WorkerRemediation(category string) string {
	switch category {
	case "configuration_error":
		return "Review project.yaml and executor settings. Do not edit generated launcher.json files."
	case "workspace_dirty":
		return "Clean, commit, or stash the reported repo files before rerunning A2O."
	case "merge_conflict":
		return "Resolve the merge conflict or update the base branch before rerunning A2O."
	case "verification_failed":
		return "Inspect the verification command output and fix product tests, lint, or dependencies."
	case "merge_failed":
		return "Check the merge target ref and branch policy before rerunning A2O."
	default:
		return "Check that the executor binary, credentials, and worker result JSON are valid."
	}
}

func SupportClassification(message string) (string, string) {
	text := strings.ToLower(message)
	switch {
	case strings.Contains(text, "project.yaml"), strings.Contains(text, "schema"), strings.Contains(text, "config"), strings.Contains(text, "executor"), strings.Contains(text, "manifest"), strings.Contains(text, "protocol"):
		return "configuration_error", "Review project.yaml and package settings, then rerun the A2O command."
	case strings.Contains(text, "dirty"), strings.Contains(text, "has changes"), strings.Contains(text, "changed files"), strings.Contains(text, "working tree"):
		return "workspace_dirty", "Clean, commit, or stash the reported repo files before rerunning A2O."
	case strings.Contains(text, "merge conflict"), strings.Contains(text, "unmerged"), strings.Contains(text, "conflict marker"):
		return "merge_conflict", "Resolve the merge conflict or update the base branch before rerunning A2O."
	case strings.Contains(text, "verification"):
		return "verification_failed", "Inspect verification output and fix product tests, lint, or dependencies."
	case strings.Contains(text, "docker"):
		return "runtime_failed", "Check Docker runtime status, compose project settings, and the printed command output."
	default:
		return "runtime_failed", "Inspect the error above, fix the reported cause, and rerun the A2O command."
	}
}
