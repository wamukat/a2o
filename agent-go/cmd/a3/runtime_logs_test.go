package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRuntimeLogsPrintsCompletedPhaseArtifacts(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		KanbalonePort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		logManifestOutput: `{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[{"phase":"implementation","artifact_id":"worker-run-16-implementation-ai-raw-log","mode":"ai-raw-log"},{"phase":"implementation","artifact_id":"worker-run-16-implementation-combined-log","mode":"combined-log"}]}`,
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== phase: implementation (ai-raw-log) artifact=worker-run-16-implementation-ai-raw-log ===") {
		t.Fatalf("runtime logs missing ai-raw-log header, got:\n%s", output)
	}
	if !strings.Contains(output, "=== phase: implementation (combined-log) artifact=worker-run-16-implementation-combined-log ===") {
		t.Fatalf("runtime logs missing combined-log header, got:\n%s", output)
	}
	if !strings.Contains(output, "agent raw log line") {
		t.Fatalf("runtime logs missing artifact content, got:\n%s", output)
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	for _, want := range []string{
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime ruby -rjson -e",
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 agent-artifact-read --storage-dir /var/lib/a3/test-runtime worker-run-16-implementation-ai-raw-log",
		"docker compose -p a3-test -f compose.yml exec -T a2o-runtime a3 agent-artifact-read --storage-dir /var/lib/a3/test-runtime worker-run-16-implementation-combined-log",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runtime logs missing call %q in:\n%s", want, joined)
		}
	}
}

func TestRuntimeLogsProjectSelectsOneRegistryProject(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeProjectRegistry(t, tempDir, multiProjectRegistryPayload(packageDir, tempDir))
	runner := &fakeRunner{
		logManifestOutput: `{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[{"phase":"implementation","artifact_id":"worker-run-16-implementation-ai-raw-log","mode":"ai-raw-log"}]}`,
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "--project", "beta", "A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := strings.Join(runner.joinedCalls(), "\n")
	for _, want := range []string{
		"docker compose -p a3-beta -f " + filepath.Join(tempDir, "compose-beta.yml"),
		" a3 show-task --storage-backend json --storage-dir /var/lib/a2o/projects/beta A2O#16",
		" a3 agent-artifact-read --storage-dir /var/lib/a2o/projects/beta worker-run-16-implementation-ai-raw-log",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runtime logs should use selected project; missing %q in:\n%s", want, joined)
		}
	}
}

func TestRuntimeLogsAcceptsQualifiedProjectRef(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeProjectRegistry(t, tempDir, multiProjectRegistryPayload(packageDir, tempDir))
	runner := &fakeRunner{
		logManifestOutput: `{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[{"phase":"implementation","artifact_id":"worker-run-16-implementation-ai-raw-log","mode":"ai-raw-log"}]}`,
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "beta:A2O#16"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	joined := strings.Join(runner.joinedCalls(), "\n")
	for _, want := range []string{
		"docker compose -p a3-beta -f " + filepath.Join(tempDir, "compose-beta.yml"),
		" a3 show-task --storage-backend json --storage-dir /var/lib/a2o/projects/beta A2O#16",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("runtime logs should strip project qualifier and use selected project; missing %q in:\n%s", want, joined)
		}
	}
}

func TestRuntimeLogsStaticModeIncludesChildArtifactsForParent(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		logManifestOutput: `{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","active":false,"artifacts":[{"task_ref":"Sample#41","phase":"planning","artifact_id":"parent-planning-combined-log","mode":"combined-log"},{"task_ref":"Sample#42","phase":"implementation","artifact_id":"child-implementation-ai-raw-log","mode":"ai-raw-log"},{"task_ref":"Sample#42","phase":"verification","artifact_id":"child-verification-combined-log","mode":"combined-log"},{"task_ref":"Sample#43","phase":"implementation","artifact_id":"child-implementation-ai-raw-log","mode":"ai-raw-log"}]}`,
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "Sample#41"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== phase: planning (combined-log) artifact=parent-planning-combined-log ===") {
		t.Fatalf("runtime logs should keep parent artifact header unchanged, got:\n%s", output)
	}
	if !strings.Contains(output, "=== task: Sample#42 phase: implementation (ai-raw-log) artifact=child-implementation-ai-raw-log ===") {
		t.Fatalf("runtime logs should include child implementation artifact with task header, got:\n%s", output)
	}
	if !strings.Contains(output, "=== task: Sample#42 phase: verification (combined-log) artifact=child-verification-combined-log ===") {
		t.Fatalf("runtime logs should include child verification artifact with task header, got:\n%s", output)
	}
	if count := strings.Count(output, "artifact=child-implementation-ai-raw-log"); count != 1 {
		t.Fatalf("runtime logs should de-duplicate child artifacts, count=%d output:\n%s", count, output)
	}
	joined := strings.Join(runner.joinedCalls(), "\n")
	if !strings.Contains(joined, "/var/lib/a3/test-runtime/tasks.json /var/lib/a3/test-runtime/runs.json Sample#41 true") {
		t.Fatalf("runtime logs should request static child aggregation, calls:\n%s", joined)
	}

	runner = &fakeRunner{
		logManifestOutput: `{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","active":false,"artifacts":[{"task_ref":"Sample#41","phase":"planning","artifact_id":"parent-planning-combined-log","mode":"combined-log"}]}`,
	}
	stdout.Reset()
	stderr.Reset()
	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "Sample#41", "--no-children"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})
	joined = strings.Join(runner.joinedCalls(), "\n")
	if !strings.Contains(joined, "/var/lib/a3/test-runtime/tasks.json /var/lib/a3/test-runtime/runs.json Sample#41 false") {
		t.Fatalf("runtime logs --no-children should request parent-only static manifest, calls:\n%s", joined)
	}
	if strings.Contains(stdout.String(), "task: Sample#42") {
		t.Fatalf("runtime logs --no-children should not include child sections, got:\n%s", stdout.String())
	}
}

func TestRuntimeLogsStaticModeFailsForMissingTaskRef(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{failShowTask: true}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "Missing#404"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("runtime logs should fail for a missing task ref")
		}
	})

	if !strings.Contains(stderr.String(), "task not found") {
		t.Fatalf("runtime logs should surface show-task failure, stderr=%q stdout=%q", stderr.String(), stdout.String())
	}
	if strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "agent-artifact-read") {
		t.Fatalf("runtime logs should not read artifacts for missing task refs")
	}
}

func TestRuntimeLogsShowsQueuedDecompositionSourceWithoutRunArtifacts(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		showTaskOutput:            "task A2O#61 kind=single status=todo current_run=\nedit_scope=\nverification_scope=\nrunnable_reason=decomposition_requested\n",
		logManifestOutput:         `{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","active":false,"artifacts":[]}`,
		decompositionStatusOutput: "decomposition task=A2O#61 state=none\n",
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "A2O#61"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"=== decomposition: A2O#61 ===",
		"decomposition task=A2O#61 state=queued",
		"decomposition_notice=no evidence has been written yet",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("runtime logs missing %q in:\n%s", want, output)
		}
	}
}

func TestRuntimeLogsShowsEvidenceBackedDecompositionStatus(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		showTaskOutput:    "task A2O#61 kind=single status=todo current_run=\nedit_scope=\nverification_scope=\nrunnable_reason=decomposition_requested\n",
		logManifestOutput: `{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","active":false,"artifacts":[]}`,
		decompositionStatusOutput: strings.Join([]string{
			"decomposition task=A2O#61 state=active",
			"proposal_fingerprint=abc123",
			"evidence.investigation=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/investigation.json",
			"",
		}, "\n"),
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "A2O#61"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"=== decomposition: A2O#61 ===",
		"decomposition task=A2O#61 state=active",
		"proposal_fingerprint=abc123",
		"evidence.investigation=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/investigation.json",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("runtime logs missing %q in:\n%s", want, output)
		}
	}
}

func TestRuntimeLogsFollowStreamsDecompositionStatusAndActionLog(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		showTaskOutput:          "task A2O#61 kind=single status=in_progress current_run=\nedit_scope=\nverification_scope=\nrunnable_reason=decomposition_requested\n",
		runtimeLogTargetsOutput: `{"requested_task_ref":"A2O#61","selected_task_ref":"A2O#61","dynamic_follow":false,"candidates":[]}`,
		logManifestOutput:       `{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","active":false,"artifacts":[]}`,
		decompositionStatusOutputs: []string{
			"decomposition task=A2O#61 state=active\nstage=investigate\n",
			"decomposition task=A2O#61 state=done\nstage=done\n",
		},
		runtimeCommandLogOutputs: []string{
			"investigation log line\n",
			"investigation log line\nfinal investigation log line\n",
		},
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "A2O#61", "--follow", "--poll-interval", "1ms"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"=== decomposition: A2O#61 ===",
		"decomposition task=A2O#61 state=active",
		"stage=investigate",
		"=== decomposition log: investigate ===",
		"investigation log line",
		"final investigation log line",
		"decomposition task=A2O#61 state=done",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("runtime logs --follow missing %q in:\n%s", want, output)
		}
	}
	if strings.Contains(output, "decomposition_follow=not_supported") {
		t.Fatalf("runtime logs --follow should not report decomposition as unsupported, got:\n%s", output)
	}
}

func TestRuntimeLogsFollowStreamsLiveDecompositionAgentOutput(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	hostRoot := filepath.Join(tempDir, ".work", "a2o", "runtime-host-agent")
	hostAgentLog := filepath.Join(hostRoot, "agent.log")
	liveLogPath := filepath.Join(hostRoot, "live-logs", "A2O-61", "decomposition_propose.log")
	if err := os.MkdirAll(filepath.Dir(liveLogPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hostAgentLog, []byte(`a2o_agent_job_event {"stage":"command_start","job_id":"job-1","task_ref":"A2O#61","command_intent":"decomposition_propose"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(liveLogPath, []byte("copilot proposal live output while command is running\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{
		showTaskOutput:          "task A2O#61 kind=single status=in_progress current_run=\nedit_scope=\nverification_scope=\nrunnable_reason=decomposition_requested\n",
		runtimeLogTargetsOutput: `{"requested_task_ref":"A2O#61","selected_task_ref":"A2O#61","dynamic_follow":false,"candidates":[]}`,
		logManifestOutput:       `{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","active":false,"artifacts":[]}`,
		decompositionStatusOutputs: []string{
			"decomposition task=A2O#61 state=active\nstage=propose\nevidence.investigation=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/investigation.json\n",
			"decomposition task=A2O#61 state=done\nstage=done\nevidence.proposal=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/proposal.json\n",
		},
		decompositionStatusHooks: []func(){
			nil,
			func() {
				if err := os.WriteFile(hostAgentLog, []byte(
					`a2o_agent_job_event {"stage":"command_start","job_id":"job-1","task_ref":"A2O#61","command_intent":"decomposition_propose"}`+"\n"+
						`a2o_agent_job_event {"stage":"command_done","job_id":"job-1","task_ref":"A2O#61","command_intent":"decomposition_propose","status":"succeeded"}`+"\n",
				), 0o644); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(liveLogPath, []byte(
					"copilot proposal live output while command is running\n"+
						"copilot proposal final output before terminal status\n",
				), 0o644); err != nil {
					t.Fatal(err)
				}
			},
		},
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "A2O#61", "--follow", "--poll-interval", "1ms"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"=== decomposition: A2O#61 ===",
		"decomposition task=A2O#61 state=active",
		"stage=propose",
		"=== decomposition agent events: propose ===",
		`"stage":"command_start"`,
		"=== decomposition live log: propose ===",
		"copilot proposal live output while command is running",
		`"stage":"command_done"`,
		"copilot proposal final output before terminal status",
		"decomposition task=A2O#61 state=done",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("runtime logs --follow missing %q in:\n%s", want, output)
		}
	}
}

func TestRuntimeLogsFollowKeepsDecompositionLiveLogsStageScoped(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	hostRoot := filepath.Join(tempDir, ".work", "a2o", "runtime-host-agent")
	hostAgentLog := filepath.Join(hostRoot, "agent.log")
	proposeLiveLogPath := filepath.Join(hostRoot, "live-logs", "A2O-61", "decomposition_propose.log")
	reviewLiveLogPath := filepath.Join(hostRoot, "live-logs", "A2O-61", "decomposition_review.log")
	if err := os.MkdirAll(filepath.Dir(proposeLiveLogPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hostAgentLog, []byte(`a2o_agent_job_event {"stage":"command_start","job_id":"job-propose","task_ref":"A2O#61","command_intent":"decomposition_propose"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(proposeLiveLogPath, []byte("proposal live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{
		showTaskOutput:          "task A2O#61 kind=single status=in_progress current_run=\nedit_scope=\nverification_scope=\nrunnable_reason=decomposition_requested\n",
		runtimeLogTargetsOutput: `{"requested_task_ref":"A2O#61","selected_task_ref":"A2O#61","dynamic_follow":false,"candidates":[]}`,
		logManifestOutput:       `{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","active":false,"artifacts":[]}`,
		decompositionStatusOutputs: []string{
			"decomposition task=A2O#61 state=active\nstage=propose\nevidence.investigation=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/investigation.json\n",
			"decomposition task=A2O#61 state=active\nstage=review\nevidence.proposal=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/proposal.json\n",
			"decomposition task=A2O#61 state=done\nstage=done\nevidence.proposal_review=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/review.json\n",
		},
		decompositionStatusHooks: []func(){
			nil,
			func() {
				if err := os.WriteFile(hostAgentLog, []byte(
					`a2o_agent_job_event {"stage":"command_start","job_id":"job-propose","task_ref":"A2O#61","command_intent":"decomposition_propose"}`+"\n"+
						`a2o_agent_job_event {"stage":"command_done","job_id":"job-propose","task_ref":"A2O#61","command_intent":"decomposition_propose","status":"succeeded"}`+"\n"+
						`a2o_agent_job_event {"stage":"command_start","job_id":"job-review","task_ref":"A2O#61","command_intent":"decomposition_review"}`+"\n",
				), 0o644); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(reviewLiveLogPath, []byte("review live output\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			},
			nil,
		},
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "A2O#61", "--follow", "--poll-interval", "1ms"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	for _, want := range []string{
		"=== decomposition live log: propose ===",
		"proposal live output",
		`"stage":"command_done","job_id":"job-propose"`,
		"=== decomposition agent events: review ===",
		`"stage":"command_start","job_id":"job-review"`,
		"=== decomposition live log: review ===",
		"review live output",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("runtime logs --follow missing %q in:\n%s", want, output)
		}
	}
	if strings.Contains(output, "=== decomposition live log: propose ===\nreview live output") {
		t.Fatalf("review live output should not be printed under the propose header:\n%s", output)
	}
}

func TestRuntimeLogsFollowWaitsForDecompositionStageCommandStartBeforeLiveLog(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	hostRoot := filepath.Join(tempDir, ".work", "a2o", "runtime-host-agent")
	hostAgentLog := filepath.Join(hostRoot, "agent.log")
	staleVerificationLogPath := filepath.Join(hostRoot, "live-logs", "A2O-61", "verification.log")
	reviewLiveLogPath := filepath.Join(hostRoot, "live-logs", "A2O-61", "decomposition_review.log")
	if err := os.MkdirAll(filepath.Dir(staleVerificationLogPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hostAgentLog, []byte(
		`a2o_agent_job_event {"stage":"command_start","job_id":"job-propose","task_ref":"A2O#61","command_intent":"decomposition_propose"}`+"\n"+
			`a2o_agent_job_event {"stage":"command_done","job_id":"job-propose","task_ref":"A2O#61","command_intent":"decomposition_propose","status":"succeeded"}`+"\n",
	), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staleVerificationLogPath, []byte("stale proposal live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{
		showTaskOutput:          "task A2O#61 kind=single status=in_progress current_run=\nedit_scope=\nverification_scope=\nrunnable_reason=decomposition_requested\n",
		runtimeLogTargetsOutput: `{"requested_task_ref":"A2O#61","selected_task_ref":"A2O#61","dynamic_follow":false,"candidates":[]}`,
		logManifestOutput:       `{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","active":false,"artifacts":[]}`,
		decompositionStatusOutputs: []string{
			"decomposition task=A2O#61 state=active\nstage=review\nevidence.proposal=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/proposal.json\n",
			"decomposition task=A2O#61 state=active\nstage=review\nevidence.proposal=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/proposal.json\n",
			"decomposition task=A2O#61 state=done\nstage=done\nevidence.proposal_review=/var/lib/a3/test-runtime/decomposition-evidence/A2O-61/review.json\n",
		},
		decompositionStatusHooks: []func(){
			nil,
			func() {
				if err := os.WriteFile(hostAgentLog, []byte(
					`a2o_agent_job_event {"stage":"command_start","job_id":"job-propose","task_ref":"A2O#61","command_intent":"decomposition_propose"}`+"\n"+
						`a2o_agent_job_event {"stage":"command_done","job_id":"job-propose","task_ref":"A2O#61","command_intent":"decomposition_propose","status":"succeeded"}`+"\n"+
						`a2o_agent_job_event {"stage":"command_start","job_id":"job-review","task_ref":"A2O#61","command_intent":"decomposition_review"}`+"\n",
				), 0o644); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(reviewLiveLogPath, []byte("review live output after command_start\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			},
			nil,
		},
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "A2O#61", "--follow", "--poll-interval", "1ms"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	output := stdout.String()
	if strings.Contains(output, "stale proposal live output") {
		t.Fatalf("stale proposal live output should not be printed under review before review command_start:\n%s", output)
	}
	for _, want := range []string{
		`"stage":"command_start","job_id":"job-review"`,
		"=== decomposition live log: review ===",
		"review live output after command_start",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("runtime logs --follow missing %q in:\n%s", want, output)
		}
	}
}

func TestRuntimeLogsFollowsLatestActiveRunWhenTaskCurrentRunIsBlank(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	liveLogRoot := filepath.Join(tempDir, "host-root", "ai-raw-logs")
	liveLogPath := filepath.Join(liveLogRoot, "A2O-16", "implementation.log")
	if err := os.MkdirAll(filepath.Dir(liveLogPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(liveLogPath, []byte("live log line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		KanbalonePort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		taskWithoutCurrentRun: true,
		logManifestOutputs: []string{
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"artifacts":[]}`,
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[]}`,
		},
	}
	t.Setenv("A2O_RUNTIME_RUN_ONCE_HOST_ROOT", filepath.Join(tempDir, "host-root"))
	t.Setenv("A2O_BUNDLE_STORAGE_DIR", "/var/lib/a3/test-runtime")
	t.Setenv("A2O_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", packageDir)

	var stdout bytes.Buffer
	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms", "A2O#16"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== phase: implementation (ai-raw-live) task=A2O#16 run=run-16 source=detached_commit:abc ===") {
		t.Fatalf("expected live header, got %q", output)
	}
	if !strings.Contains(output, "live log line") {
		t.Fatalf("expected live log body, got %q", output)
	}
}

func TestRuntimeLogsFollowsLatestActiveRunWhenTaskCurrentRunIsStale(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	liveLogRoot := filepath.Join(tempDir, "host-root", "ai-raw-logs")
	liveLogPath := filepath.Join(liveLogRoot, "A2O-16", "implementation.log")
	if err := os.MkdirAll(filepath.Dir(liveLogPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(liveLogPath, []byte("stale current run fallback\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		KanbalonePort:  "3480",
		AgentPort:      "7394",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		staleCurrentRun: true,
		logManifestOutputs: []string{
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"artifacts":[]}`,
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"artifacts":[]}`,
		},
	}
	t.Setenv("A2O_RUNTIME_RUN_ONCE_HOST_ROOT", filepath.Join(tempDir, "host-root"))
	t.Setenv("A2O_BUNDLE_STORAGE_DIR", "/var/lib/a3/test-runtime")
	t.Setenv("A2O_RUNTIME_RUN_ONCE_REFERENCE_PACKAGE", packageDir)

	var stdout bytes.Buffer
	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms", "A2O#16"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== phase: implementation (ai-raw-live) task=A2O#16 run=run-16 source=detached_commit:abc ===") {
		t.Fatalf("expected live header, got %q", output)
	}
	if !strings.Contains(output, "stale current run fallback") {
		t.Fatalf("expected live log body, got %q", output)
	}
}

func TestRuntimeLogsAcceptsFollowAfterTaskRef(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		logManifestOutputs: []string{
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"live_mode":"ai-raw-log","artifacts":[]}`,
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"live_mode":"ai-raw-log","artifacts":[]}`,
		},
	}
	liveRoot := filepath.Join(tempDir, runtimeHostAgentRelativePath, "ai-raw-logs", "Sample-42")
	if err := os.MkdirAll(liveRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(liveRoot, "implementation.log"), []byte("live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "Sample#42", "--follow"}, runner, &stdout, &stderr)
		if code != 0 {
			t.Fatalf("run returned %d, stderr=%s", code, stderr.String())
		}
	})

	if !strings.Contains(stdout.String(), "=== phase: implementation (ai-raw-live) task=Sample#42 run=run-16") {
		t.Fatalf("runtime logs should follow after task ref, got:\n%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "live output") {
		t.Fatalf("runtime logs should print live output, got:\n%s", stdout.String())
	}
}

func TestRuntimeLogsFollowAutoSelectsOnlyRunningTask(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		runtimeLogTargetsOutput: `{"requested_task_ref":"","selected_task_ref":"","candidates":[{"task_ref":"A2O#16","run_ref":"run-16","phase":"implementation","kind":"single","parent_ref":""}]}`,
		logManifestOutputs: []string{
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"live_mode":"ai-raw-log","artifacts":[]}`,
			`{"run_ref":"run-16","current_run":"run-16","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"live_mode":"ai-raw-log","artifacts":[]}`,
		},
	}
	liveRoot := filepath.Join(tempDir, runtimeHostAgentRelativePath, "ai-raw-logs", "A2O-16")
	if err := os.MkdirAll(liveRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(liveRoot, "implementation.log"), []byte("auto selected live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer

	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	if !strings.Contains(stdout.String(), "=== phase: implementation (ai-raw-live) task=A2O#16 run=run-16") {
		t.Fatalf("runtime logs should auto-select the only running task, got:\n%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "auto selected live output") {
		t.Fatalf("runtime logs should print auto-selected live output, got:\n%s", stdout.String())
	}
	if !strings.Contains(strings.Join(runner.joinedCalls(), "\n"), "current_run_ref") {
		t.Fatalf("runtime logs follow target query should filter candidates through task current_run_ref")
	}
}

func TestRuntimeLogsFollowRequiresIndexForMultipleRunningTasks(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		runtimeLogTargetsOutput: `{"requested_task_ref":"","selected_task_ref":"","candidates":[{"task_ref":"A2O#16","run_ref":"run-16","phase":"implementation","kind":"single","parent_ref":""},{"task_ref":"A2O#17","run_ref":"run-17","phase":"review","kind":"child","parent_ref":"A2O#15"}]}`,
	}
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	withChdir(t, tempDir, func() {
		code := run([]string{"runtime", "logs", "--follow"}, runner, &stdout, &stderr)
		if code == 0 {
			t.Fatalf("runtime logs should fail when multiple tasks match")
		}
	})

	if !strings.Contains(stderr.String(), "multiple running tasks match") || !strings.Contains(stderr.String(), "[1] task=A2O#17") {
		t.Fatalf("runtime logs should print indexed candidates, got stderr:\n%s", stderr.String())
	}
}

func TestRuntimeLogsFollowIndexSelectsRunningTask(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		runtimeLogTargetsOutput: `{"requested_task_ref":"","selected_task_ref":"","candidates":[{"task_ref":"A2O#16","run_ref":"run-16","phase":"implementation","kind":"single","parent_ref":""},{"task_ref":"Sample#42","run_ref":"run-42","phase":"implementation","kind":"child","parent_ref":"Sample#41"}]}`,
		logManifestOutputs: []string{
			`{"run_ref":"run-42","current_run":"run-42","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"live_mode":"ai-raw-log","artifacts":[]}`,
			`{"run_ref":"run-42","current_run":"run-42","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"live_mode":"ai-raw-log","artifacts":[]}`,
		},
	}
	liveRoot := filepath.Join(tempDir, runtimeHostAgentRelativePath, "ai-raw-logs", "Sample-42")
	if err := os.MkdirAll(liveRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(liveRoot, "implementation.log"), []byte("indexed live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer

	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--index", "1", "--poll-interval", "1ms"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	if !strings.Contains(stdout.String(), "=== phase: implementation (ai-raw-live) task=Sample#42 run=run-42") {
		t.Fatalf("runtime logs should follow indexed task, got:\n%s", stdout.String())
	}
	if !strings.Contains(stdout.String(), "indexed live output") {
		t.Fatalf("runtime logs should print indexed task output, got:\n%s", stdout.String())
	}
}

func TestRuntimeLogsFollowParentSelectsActiveChildUnlessNoChildren(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		runtimeLogTargetsOutput: `{"requested_task_ref":"Sample#41","selected_task_ref":"","candidates":[{"task_ref":"Sample#42","run_ref":"run-42","phase":"implementation","kind":"child","parent_ref":"Sample#41"}]}`,
		logManifestOutputs: []string{
			`{"run_ref":"run-42","current_run":"run-42","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":true,"live_mode":"ai-raw-log","artifacts":[]}`,
			`{"run_ref":"run-42","current_run":"run-42","phase":"implementation","source_type":"detached_commit","source_ref":"abc","active":false,"live_mode":"ai-raw-log","artifacts":[]}`,
		},
	}
	liveRoot := filepath.Join(tempDir, runtimeHostAgentRelativePath, "ai-raw-logs", "Sample-42")
	if err := os.MkdirAll(liveRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(liveRoot, "implementation.log"), []byte("child live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer

	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms", "Sample#41"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	if !strings.Contains(stdout.String(), "task=Sample#42") {
		t.Fatalf("runtime logs should follow active child for parent ref, got:\n%s", stdout.String())
	}

	runner.runtimeLogTargetsOutput = `{"requested_task_ref":"Sample#41","selected_task_ref":"Sample#41","candidates":[]}`
	runner.logManifestOutputs = []string{
		`{"run_ref":"run-41","current_run":"run-41","phase":"review","source_type":"detached_commit","source_ref":"abc","active":true,"live_mode":"ai-raw-log","artifacts":[]}`,
		`{"run_ref":"run-41","current_run":"run-41","phase":"review","source_type":"detached_commit","source_ref":"abc","active":false,"live_mode":"ai-raw-log","artifacts":[]}`,
	}
	parentLiveRoot := filepath.Join(tempDir, runtimeHostAgentRelativePath, "ai-raw-logs", "Sample-41")
	if err := os.MkdirAll(parentLiveRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parentLiveRoot, "review.log"), []byte("parent live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	stdout.Reset()

	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--no-children", "--poll-interval", "1ms", "Sample#41"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	if !strings.Contains(stdout.String(), "task=Sample#41") || !strings.Contains(stdout.String(), "parent live output") {
		t.Fatalf("runtime logs --no-children should follow parent itself, got:\n%s", stdout.String())
	}
}

func TestRuntimeLogsFollowParentReResolvesAfterChildCompletes(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		runtimeLogTargetsOutputs: []string{
			`{"requested_task_ref":"Sample#41","selected_task_ref":"","dynamic_follow":true,"candidates":[{"task_ref":"Sample#42","run_ref":"run-child","phase":"implementation","kind":"child","parent_ref":"Sample#41"}]}`,
			`{"requested_task_ref":"Sample#41","selected_task_ref":"Sample#41","dynamic_follow":true,"candidates":[]}`,
			`{"requested_task_ref":"Sample#41","selected_task_ref":"Sample#41","dynamic_follow":true,"candidates":[]}`,
		},
		logManifestOutputs: []string{
			`{"run_ref":"run-child","current_run":"run-child","phase":"implementation","source_type":"detached_commit","source_ref":"child","task_status":"in_progress","active":true,"live_mode":"ai-raw-log","artifacts":[]}`,
			`{"run_ref":"run-child","current_run":"run-child","phase":"implementation","source_type":"detached_commit","source_ref":"child","task_status":"Done","active":false,"live_mode":"ai-raw-log","artifacts":[]}`,
			`{"run_ref":"run-parent","current_run":"run-parent","phase":"review","source_type":"detached_commit","source_ref":"parent","task_status":"In review","active":true,"live_mode":"ai-raw-log","artifacts":[]}`,
			`{"run_ref":"run-parent","current_run":"run-parent","phase":"review","source_type":"detached_commit","source_ref":"parent","task_status":"Done","active":false,"live_mode":"ai-raw-log","artifacts":[]}`,
		},
	}
	childLiveRoot := filepath.Join(tempDir, runtimeHostAgentRelativePath, "ai-raw-logs", "Sample-42")
	if err := os.MkdirAll(childLiveRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(childLiveRoot, "implementation.log"), []byte("child live output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	parentLiveRoot := filepath.Join(tempDir, runtimeHostAgentRelativePath, "ai-raw-logs", "Sample-41")
	if err := os.MkdirAll(parentLiveRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(parentLiveRoot, "review.log"), []byte("parent runner output\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout bytes.Buffer

	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms", "Sample#41"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== phase: implementation (ai-raw-live) task=Sample#42 run=run-child") || !strings.Contains(output, "child live output") {
		t.Fatalf("runtime logs should start by following active child, got:\n%s", output)
	}
	if !strings.Contains(output, "=== switching: task=Sample#42 -> task=Sample#41 ===") {
		t.Fatalf("runtime logs should announce parent follow target switch, got:\n%s", output)
	}
	if !strings.Contains(output, "=== phase: review (ai-raw-live) task=Sample#41 run=run-parent") || !strings.Contains(output, "parent runner output") {
		t.Fatalf("runtime logs should continue with parent stream after child completion, got:\n%s", output)
	}
}

func TestRuntimeLogsFollowWaitsAcrossPhaseTransition(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		taskStatus: "Merging",
		logManifestOutputs: []string{
			`{"run_ref":"run-review","current_run":"run-review","phase":"parent_review","source_type":"detached_commit","source_ref":"abc","task_status":"Merging","active":false,"artifacts":[{"phase":"parent_review","artifact_id":"worker-run-review-parent-review-combined-log","mode":"combined-log"}]}`,
			`{"run_ref":"run-merge","current_run":"run-merge","phase":"merge","source_type":"branch_head","source_ref":"refs/heads/a2o/work/Sample-42","task_status":"Merging","active":true,"artifacts":[{"phase":"parent_review","artifact_id":"worker-run-review-parent-review-combined-log","mode":"combined-log"}]}`,
			`{"run_ref":"run-merge","current_run":"run-merge","phase":"merge","source_type":"branch_head","source_ref":"refs/heads/a2o/work/Sample-42","task_status":"Done","active":false,"artifacts":[{"phase":"parent_review","artifact_id":"worker-run-review-parent-review-combined-log","mode":"combined-log"},{"phase":"merge","artifact_id":"worker-run-merge-merge-combined-log","mode":"combined-log"}]}`,
		},
	}
	var stdout bytes.Buffer

	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms", "A2O#16"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	output := stdout.String()
	if !strings.Contains(output, "=== waiting: task=A2O#16 status=Merging next phase/run ===") {
		t.Fatalf("runtime logs should wait between runs, got:\n%s", output)
	}
	if !strings.Contains(output, "=== phase: merge (live) task=A2O#16 run=run-merge source=branch_head:refs/heads/a2o/work/Sample-42 ===") {
		t.Fatalf("runtime logs should attach to the merge phase after waiting, got:\n%s", output)
	}
	if !strings.Contains(output, "=== phase: merge (combined-log) artifact=worker-run-merge-merge-combined-log ===") {
		t.Fatalf("runtime logs should print merge artifact after the phase completes, got:\n%s", output)
	}
	if count := strings.Count(output, "artifact=worker-run-review-parent-review-combined-log"); count != 1 {
		t.Fatalf("runtime logs should de-duplicate artifacts across polls, count=%d output:\n%s", count, output)
	}
}

func TestRuntimeLogsFollowReturnsForQueuedTaskWithoutRun(t *testing.T) {
	tempDir := t.TempDir()
	packageDir := filepath.Join(tempDir, "package")
	if err := os.MkdirAll(packageDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMultiRepoProjectYaml(t, packageDir)
	writeTestInstanceConfig(t, tempDir, runtimeInstanceConfig{
		SchemaVersion:  1,
		PackagePath:    packageDir,
		WorkspaceRoot:  tempDir,
		ComposeFile:    "compose.yml",
		ComposeProject: "a3-test",
		RuntimeService: "a2o-runtime",
		StorageDir:     "/var/lib/a3/test-runtime",
	})
	runner := &fakeRunner{
		taskStatus:            "todo",
		taskWithoutCurrentRun: true,
		logManifestOutputs: []string{
			`{"run_ref":"","current_run":"","phase":"","source_type":"","source_ref":"","task_status":"todo","active":false,"artifacts":[]}`,
		},
	}
	var stdout bytes.Buffer

	withChdir(t, tempDir, func() {
		if err := runRuntimeLogs([]string{"--follow", "--poll-interval", "1ms", "A2O#16"}, runner, &stdout, io.Discard); err != nil {
			t.Fatal(err)
		}
	})

	if strings.Contains(stdout.String(), "=== waiting:") {
		t.Fatalf("queued task without a run should return instead of waiting, got:\n%s", stdout.String())
	}
	if len(runner.logManifestOutputs) != 0 {
		t.Fatalf("runtime logs should not poll again for queued task, remaining manifests=%d", len(runner.logManifestOutputs))
	}
}
