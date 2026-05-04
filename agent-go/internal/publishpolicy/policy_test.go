package publishpolicy

import "testing"

func TestNormalizeCommitHookDefaultsBlankPolicyToBypass(t *testing.T) {
	if got := NormalizeCommitHook("  "); got != CommitHookBypass {
		t.Fatalf("NormalizeCommitHook blank = %q, want %q", got, CommitHookBypass)
	}
}

func TestValidateCommitHookAcceptsKnownPolicies(t *testing.T) {
	for _, policy := range []string{"", CommitHookBypass, CommitHookRun} {
		if err := ValidateCommitHook(policy); err != nil {
			t.Fatalf("ValidateCommitHook(%q) returned error: %v", policy, err)
		}
	}
}

func TestValidateCommitHookRejectsUnknownPolicy(t *testing.T) {
	if err := ValidateCommitHook("sometimes"); err == nil {
		t.Fatal("ValidateCommitHook should reject unknown policy")
	}
}
