package publishpolicy

import "testing"

func TestNormalizeNativeGitHooksDefaultsBlankPolicyToBypass(t *testing.T) {
	if got := NormalizeNativeGitHooks("  "); got != NativeGitHooksBypass {
		t.Fatalf("NormalizeNativeGitHooks blank = %q, want %q", got, NativeGitHooksBypass)
	}
}

func TestValidateNativeGitHooksAcceptsKnownPolicies(t *testing.T) {
	for _, policy := range []string{"", NativeGitHooksBypass, NativeGitHooksRun} {
		if err := ValidateNativeGitHooks(policy); err != nil {
			t.Fatalf("ValidateNativeGitHooks(%q) returned error: %v", policy, err)
		}
	}
}

func TestValidateNativeGitHooksRejectsUnknownPolicy(t *testing.T) {
	if err := ValidateNativeGitHooks("sometimes"); err == nil {
		t.Fatal("ValidateNativeGitHooks should reject unknown policy")
	}
}

func TestValidateConfiguredNativeGitHooksRejectsExplicitBlankPolicy(t *testing.T) {
	if err := ValidateConfiguredNativeGitHooks("   "); err == nil {
		t.Fatal("ValidateConfiguredNativeGitHooks should reject explicit whitespace policy")
	}
}
