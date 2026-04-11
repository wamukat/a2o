package agent

import (
	"encoding/json"
	"testing"
)

func TestJobRequestWorkspaceRequestRoundTrip(t *testing.T) {
	payload := []byte(`{
		"job_id": "job-1",
		"task_ref": "Portal#42",
		"phase": "implementation",
		"runtime_profile": "host-local",
		"source_descriptor": {
			"workspace_kind": "ticket_workspace",
			"source_type": "branch_head",
			"ref": "refs/heads/a3/work/Portal-42",
			"task_ref": "Portal#42"
		},
		"workspace_request": {
			"mode": "agent_materialized",
			"workspace_kind": "ticket_workspace",
			"workspace_id": "Portal-42-ticket",
			"freshness_policy": "reuse_if_clean_and_ref_matches",
			"cleanup_policy": "retain_until_a3_cleanup",
			"slots": {
				"repo_alpha": {
					"source": {
						"kind": "local_git",
						"alias": "member-portal-starters"
					},
					"ref": "refs/heads/a3/work/Portal-42",
					"checkout": "worktree_detached",
					"access": "read_write",
					"required": true
				}
			}
		},
		"working_dir": ".",
		"command": "sh",
		"args": ["worker.sh"],
		"env": {},
		"timeout_seconds": 60,
		"artifact_rules": []
	}`)

	var request JobRequest
	if err := json.Unmarshal(payload, &request); err != nil {
		t.Fatal(err)
	}
	if request.WorkspaceRequest == nil {
		t.Fatal("workspace request was not decoded")
	}
	slot := request.WorkspaceRequest.Slots["repo_alpha"]
	if slot.Source.Alias != "member-portal-starters" || slot.Checkout != "worktree_detached" {
		t.Fatalf("unexpected slot request: %#v", slot)
	}

	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip JobRequest
	if err := json.Unmarshal(encoded, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if roundTrip.WorkspaceRequest == nil || roundTrip.WorkspaceRequest.WorkspaceID != "Portal-42-ticket" {
		t.Fatalf("unexpected roundtrip request: %#v", roundTrip.WorkspaceRequest)
	}
}
