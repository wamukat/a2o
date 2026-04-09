# frozen_string_literal: true

RSpec.describe A3::Domain::Run do
  let(:source_descriptor) do
    A3::Domain::SourceDescriptor.new(
      workspace_kind: :ticket_workspace,
      source_type: :branch_head,
      ref: "refs/heads/a3/work/3025",
      task_ref: "A3-v2#3025"
    )
  end

  let(:scope_snapshot) do
    A3::Domain::ScopeSnapshot.new(
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      ownership_scope: :task
    )
  end

  let(:review_target) do
    A3::Domain::ReviewTarget.new(
      base_commit: "base123",
      head_commit: "head456",
      task_ref: "A3-v2#3025",
      phase_ref: :review
    )
  end

  let(:artifact_owner) do
    A3::Domain::ArtifactOwner.new(
      owner_ref: "A3-v2#3025",
      owner_scope: :task,
      snapshot_version: "snap-1"
    )
  end

  it "keeps canonical run-level evidence" do
    run = described_class.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    expect(run.evidence.review_target).to eq(review_target)
    expect(run.evidence.source_descriptor.workspace_kind).to eq(:runtime_workspace)
    expect(run.evidence.scope_snapshot).to eq(scope_snapshot)
  end

  it "appends phase evidence without mutating previous entries" do
    run = described_class.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    next_run = run.append_phase_evidence(
      phase: :verification,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      verification_summary: "all green",
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "all green",
        observed_state: "commands succeeded",
        diagnostics: { "stdout" => "ok" }
      )
    )

    expect(run.phase_records.size).to eq(1)
    expect(next_run.phase_records.size).to eq(2)
    expect(next_run.phase_records.last.phase).to eq(:verification)
    expect(next_run.phase_records.last.verification_summary).to eq("all green")
    expect(next_run.phase_records.last.execution_record).to have_attributes(
      summary: "all green",
      observed_state: "commands succeeded"
    )
  end

  it "preserves terminal outcome when appending phase evidence" do
    run = described_class.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner,
      terminal_outcome: :completed
    )

    next_run = run.append_phase_evidence(
      phase: :merge,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      verification_summary: "merge confirmed",
      execution_record: A3::Domain::PhaseExecutionRecord.new(summary: "merge confirmed")
    )

    expect(run.terminal_outcome).to eq(:completed)
    expect(next_run.terminal_outcome).to eq(:completed)
    expect(next_run).not_to equal(run)
  end

  it "appends blocked diagnosis without mutating previous entries" do
    run = described_class.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    updated = run.append_blocked_diagnosis(
      A3::Domain::BlockedDiagnosis.new(
        task_ref: "A3-v2#3025",
        run_ref: "run-1",
        phase: :review,
        outcome: :blocked,
        review_target: review_target,
        source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
        scope_snapshot: scope_snapshot,
        artifact_owner: artifact_owner,
        expected_state: "runtime workspace available",
        observed_state: "repo-beta missing",
        failing_command: "codex exec --json -",
        diagnostic_summary: "review launch could not resolve runtime workspace",
        infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
      )
    )

    expect(run.phase_records.last.blocked_diagnosis).to be_nil
    expect(updated.phase_records.last.blocked_diagnosis&.diagnostic_summary).to eq("review launch could not resolve runtime workspace")
    expect(updated).not_to equal(run)
  end

  it "restores from persisted evidence without needing hidden mutation" do
    original = described_class.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    restored = described_class.restore(
      ref: original.ref,
      task_ref: original.task_ref,
      phase: original.phase,
      workspace_kind: original.workspace_kind,
      source_descriptor: original.source_descriptor,
      scope_snapshot: original.scope_snapshot,
      artifact_owner: original.artifact_owner,
      evidence: original.evidence,
      terminal_outcome: :completed
    )

    expect(restored.ref).to eq("run-1")
    expect(restored.evidence).to eq(original.evidence)
    expect(restored.terminal_outcome).to eq(:completed)
  end

  it "rejects restored evidence when run-level canonical fields drift" do
    original = described_class.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )
    drifted_evidence = A3::Domain::EvidenceRecord.new(
      task_ref: original.task_ref,
      review_target: original.evidence.review_target,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "different-head",
        task_ref: original.task_ref
      ),
      scope_snapshot: original.evidence.scope_snapshot,
      artifact_owner: original.evidence.artifact_owner,
      phase_records: original.evidence.phase_records
    )

    expect do
      described_class.restore(
        ref: original.ref,
        task_ref: original.task_ref,
        phase: original.phase,
        workspace_kind: original.workspace_kind,
        source_descriptor: original.source_descriptor,
        scope_snapshot: original.scope_snapshot,
        artifact_owner: original.artifact_owner,
        evidence: drifted_evidence
      )
    end.to raise_error(A3::Domain::ConfigurationError, /source_descriptor/)
  end

  it "rejects restored runs when workspace_kind drifts from source descriptor" do
    original = described_class.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor.with_workspace_kind(:runtime_workspace),
      scope_snapshot: scope_snapshot,
      review_target: review_target,
      artifact_owner: artifact_owner
    )

    expect do
      described_class.restore(
        ref: original.ref,
        task_ref: original.task_ref,
        phase: original.phase,
        workspace_kind: :ticket_workspace,
        source_descriptor: original.source_descriptor,
        scope_snapshot: original.scope_snapshot,
        artifact_owner: original.artifact_owner,
        evidence: original.evidence
      )
    end.to raise_error(A3::Domain::ConfigurationError, /workspace_kind/)
  end
end
