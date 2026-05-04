package publishpolicy

import (
	"fmt"
	"strings"
)

const (
	CommitHookBypass = "bypass"
	CommitHookRun    = "run"
)

func NormalizeCommitHook(policy string) string {
	policy = strings.TrimSpace(policy)
	if policy == "" {
		return CommitHookBypass
	}
	return policy
}

func ValidCommitHook(policy string) bool {
	return policy == CommitHookBypass || policy == CommitHookRun
}

func ValidateCommitHook(policy string) error {
	if ValidCommitHook(NormalizeCommitHook(policy)) {
		return nil
	}
	return fmt.Errorf("commit_hook_policy must be %s or %s", CommitHookBypass, CommitHookRun)
}
