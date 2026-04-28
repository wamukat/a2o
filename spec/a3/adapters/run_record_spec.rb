# frozen_string_literal: true

RSpec.describe A3::Adapters::RunRecord do
  it "serializes and restores a run with evidence" do
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: "A3-v2#3025",
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :parent,
        snapshot_version: "snap-1"
      )
    ).append_phase_evidence(
      phase: :verification,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      verification_summary: "all green",
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "all green",
        observed_state: "commands succeeded",
        diagnostics: { "stdout" => "ok" },
        runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.new(
          task_kind: :child,
          repo_scope: :repo_alpha,
          phase: :verification,
          implementation_skill: "sample-implementation",
          review_skill: "sample-review",
          verification_commands: ["commands/check-style", "commands/verify-all"],
          remediation_commands: ["commands/apply-remediation"],
          workspace_hook: "sample-bootstrap",
          merge_target: :merge_to_parent,
          merge_policy: :ff_only
        )
      )
    )

    record = described_class.dump(run)
    restored = described_class.load(record)

    expect(record["ref"]).to eq("run-1")
    expect(record["project_key"]).to be_nil
    expect(record["phase"]).to eq("verification")
    expect(record["artifact_owner"]["snapshot_version"]).to eq("snap-1")
    expect(record["evidence"]["review_target"]["head_commit"]).to eq("head456")
    expect(record["evidence"]["phase_records"].size).to eq(2)
    expect(restored).to eq(run)
    expect(restored.phase_records.last.verification_summary).to eq("all green")
    expect(restored.phase_records.last.execution_record&.diagnostics).to eq({ "stdout" => "ok" })
    expect(restored.phase_records.last.execution_record&.runtime_snapshot).to have_attributes(
      repo_scope: :repo_alpha,
      verification_commands: ["commands/check-style", "commands/verify-all"],
      remediation_commands: ["commands/apply-remediation"],
      merge_target: :merge_to_parent
    )
  end

  it "serializes project identity across the run and its evidence" do
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A2O#312",
      phase: :implementation,
      workspace_kind: :runtime_workspace,
      project_key: "a2o",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "A2O#312", ref: "head456"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:a2o],
        verification_scope: [:a2o],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A2O#312",
        owner_scope: :task,
        snapshot_version: "snap-1"
      )
    )

    record = described_class.dump(run)

    expect(record.fetch("project_key")).to eq("a2o")
    expect(record.fetch("evidence").fetch("project_key")).to eq("a2o")
    expect(described_class.load(record)).to eq(run)
  end

  it "fails fast when persisted run-level fields and evidence drift" do
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: "A3-v2#3025",
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: "A3-v2#3025"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: "A3-v2#3025",
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :parent,
        snapshot_version: "snap-1"
      )
    )
    record = described_class.dump(run)
    record.fetch("evidence").fetch("source_descriptor")["ref"] = "different-head"

    expect do
      described_class.load(record)
    end.to raise_error(A3::Domain::ConfigurationError, /source_descriptor/)
  end
end
