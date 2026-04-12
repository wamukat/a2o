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
					"checkout": "worktree_branch",
					"access": "read_write",
					"sync_class": "eager",
					"ownership": "edit_target",
					"required": true
				}
			}
		},
		"worker_protocol_request": {
			"task_ref": "Portal#42",
			"phase": "implementation"
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
	if request.WorkerProtocolRequest["task_ref"] != "Portal#42" {
		t.Fatalf("worker protocol request was not decoded: %#v", request.WorkerProtocolRequest)
	}
	slot := request.WorkspaceRequest.Slots["repo_alpha"]
	if slot.Source.Alias != "member-portal-starters" || slot.Checkout != "worktree_branch" || slot.SyncClass != "eager" || slot.Ownership != "edit_target" {
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
	if roundTrip.WorkerProtocolRequest["phase"] != "implementation" {
		t.Fatalf("unexpected roundtrip worker protocol request: %#v", roundTrip.WorkerProtocolRequest)
	}
}

func TestJobResultWorkerProtocolResultRoundTrip(t *testing.T) {
	payload := []byte(`{
		"job_id": "job-1",
		"status": "succeeded",
		"exit_code": 0,
		"started_at": "2026-04-11T00:00:00Z",
		"finished_at": "2026-04-11T00:00:01Z",
		"summary": "ok",
		"log_uploads": [],
		"artifact_uploads": [],
		"workspace_descriptor": {
			"workspace_kind": "ticket_workspace",
			"runtime_profile": "host-local",
			"workspace_id": "Portal-42-ticket",
			"source_descriptor": {
				"workspace_kind": "ticket_workspace",
				"source_type": "branch_head",
				"ref": "refs/heads/a3/work/Portal-42",
				"task_ref": "Portal#42"
			},
			"slot_descriptors": {}
		},
		"worker_protocol_result": {
			"status": "succeeded",
			"task_ref": "Portal#42"
		}
	}`)

	var result JobResult
	if err := json.Unmarshal(payload, &result); err != nil {
		t.Fatal(err)
	}
	if result.WorkerProtocolResult["status"] != "succeeded" {
		t.Fatalf("worker protocol result was not decoded: %#v", result.WorkerProtocolResult)
	}
	encoded, err := json.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip JobResult
	if err := json.Unmarshal(encoded, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if roundTrip.WorkerProtocolResult["task_ref"] != "Portal#42" {
		t.Fatalf("unexpected roundtrip worker protocol result: %#v", roundTrip.WorkerProtocolResult)
	}
}
