package publishpolicy

import (
	"fmt"
	"strings"
)

const (
	NativeGitHooksBypass = "bypass"
	NativeGitHooksRun    = "run"
)

func NormalizeNativeGitHooks(policy string) string {
	policy = strings.TrimSpace(policy)
	if policy == "" {
		return NativeGitHooksBypass
	}
	return policy
}

func ValidNativeGitHooks(policy string) bool {
	return policy == NativeGitHooksBypass || policy == NativeGitHooksRun
}

func ValidateNativeGitHooks(policy string) error {
	if ValidNativeGitHooks(NormalizeNativeGitHooks(policy)) {
		return nil
	}
	return fmt.Errorf("commit_preflight.native_git_hooks must be %s or %s", NativeGitHooksBypass, NativeGitHooksRun)
}

func ValidateConfiguredNativeGitHooks(policy string) error {
	if ValidNativeGitHooks(policy) {
		return nil
	}
	return fmt.Errorf("commit_preflight.native_git_hooks must be %s or %s", NativeGitHooksBypass, NativeGitHooksRun)
}
