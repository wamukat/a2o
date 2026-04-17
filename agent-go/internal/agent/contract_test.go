package agent

import (
	"encoding/json"
	"testing"
)

func TestJobRequestWorkspaceRequestRoundTrip(t *testing.T) {
	payload := []byte(`{
		"job_id": "job-1",
		"task_ref": "Sample#42",
		"phase": "implementation",
		"runtime_profile": "host-local",
		"source_descriptor": {
			"workspace_kind": "ticket_workspace",
			"source_type": "branch_head",
			"ref": "refs/heads/a3/work/Sample-42",
			"task_ref": "Sample#42"
		},
		"workspace_request": {
			"mode": "agent_materialized",
			"workspace_kind": "ticket_workspace",
			"workspace_id": "Sample-42-ticket",
			"freshness_policy": "reuse_if_clean_and_ref_matches",
			"cleanup_policy": "retain_until_a3_cleanup",
			"publish_policy": {
				"mode": "commit_all_edit_target_changes_on_worker_success",
				"commit_message": "A3 implementation update for Sample#42"
			},
			"slots": {
				"repo_alpha": {
					"source": {
						"kind": "local_git",
						"alias": "sample-catalog-service"
					},
					"ref": "refs/heads/a3/work/Sample-42",
					"bootstrap_ref": "refs/heads/feature/prototype",
					"checkout": "worktree_branch",
					"access": "read_write",
					"sync_class": "eager",
					"ownership": "edit_target",
					"required": true
				}
			}
		},
		"worker_protocol_request": {
			"task_ref": "Sample#42",
			"phase": "implementation"
		},
		"agent_environment": {
			"workspace_root": "/agent/workspaces",
			"source_paths": {
				"sample-catalog-service": "/agent/repos/starters"
			},
			"env": {
				"A3_ROOT_DIR": "/agent/a3"
			},
			"required_bins": ["git", "task"]
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
	if request.WorkspaceRequest.PublishPolicy == nil || request.WorkspaceRequest.PublishPolicy.Mode != "commit_all_edit_target_changes_on_worker_success" {
		t.Fatalf("workspace publish policy was not decoded: %#v", request.WorkspaceRequest.PublishPolicy)
	}
	if request.WorkerProtocolRequest["task_ref"] != "Sample#42" {
		t.Fatalf("worker protocol request was not decoded: %#v", request.WorkerProtocolRequest)
	}
	if request.AgentEnvironment == nil || request.AgentEnvironment.WorkspaceRoot != "/agent/workspaces" {
		t.Fatalf("agent environment was not decoded: %#v", request.AgentEnvironment)
	}
	if request.AgentEnvironment.SourcePaths["sample-catalog-service"] != "/agent/repos/starters" {
		t.Fatalf("agent source paths were not decoded: %#v", request.AgentEnvironment.SourcePaths)
	}
	if request.AgentEnvironment.Env["A3_ROOT_DIR"] != "/agent/a3" {
		t.Fatalf("agent env was not decoded: %#v", request.AgentEnvironment.Env)
	}
	if len(request.AgentEnvironment.RequiredBins) != 2 || request.AgentEnvironment.RequiredBins[0] != "git" {
		t.Fatalf("agent required bins were not decoded: %#v", request.AgentEnvironment.RequiredBins)
	}
	slot := request.WorkspaceRequest.Slots["repo_alpha"]
	if slot.Source.Alias != "sample-catalog-service" || slot.Checkout != "worktree_branch" || slot.SyncClass != "eager" || slot.Ownership != "edit_target" {
		t.Fatalf("unexpected slot request: %#v", slot)
	}
	if slot.BootstrapRef != "refs/heads/feature/prototype" {
		t.Fatalf("workspace bootstrap ref was not decoded: %#v", slot)
	}

	encoded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip JobRequest
	if err := json.Unmarshal(encoded, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if roundTrip.WorkspaceRequest == nil || roundTrip.WorkspaceRequest.WorkspaceID != "Sample-42-ticket" {
		t.Fatalf("unexpected roundtrip request: %#v", roundTrip.WorkspaceRequest)
	}
	if roundTrip.WorkerProtocolRequest["phase"] != "implementation" {
		t.Fatalf("unexpected roundtrip worker protocol request: %#v", roundTrip.WorkerProtocolRequest)
	}
	if roundTrip.AgentEnvironment == nil || roundTrip.AgentEnvironment.SourcePaths["sample-catalog-service"] != "/agent/repos/starters" {
		t.Fatalf("unexpected roundtrip agent environment: %#v", roundTrip.AgentEnvironment)
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
			"workspace_id": "Sample-42-ticket",
			"source_descriptor": {
				"workspace_kind": "ticket_workspace",
				"source_type": "branch_head",
				"ref": "refs/heads/a3/work/Sample-42",
				"task_ref": "Sample#42"
			},
			"slot_descriptors": {}
		},
		"worker_protocol_result": {
			"status": "succeeded",
			"task_ref": "Sample#42"
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
	if roundTrip.WorkerProtocolResult["task_ref"] != "Sample#42" {
		t.Fatalf("unexpected roundtrip worker protocol result: %#v", roundTrip.WorkerProtocolResult)
	}
}
