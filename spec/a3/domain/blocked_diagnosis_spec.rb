# frozen_string_literal: true

RSpec.describe A3::Domain::BlockedDiagnosis do
  it "keeps the canonical blocked diagnosis bundle immutable" do
    diagnosis = described_class.new(
      task_ref: "A3-v2#3025",
      run_ref: "run-1",
      phase: :review,
      outcome: :blocked,
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: "A3-v2#3025",
        phase_ref: :review
      ),
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
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      ),
      expected_state: "runtime workspace available",
      observed_state: "repo-beta missing",
      failing_command: "codex exec --json -",
      diagnostic_summary: "review launch could not resolve runtime workspace",
      infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
    )

    expect(diagnosis.task_ref).to eq("A3-v2#3025")
    expect(diagnosis.outcome).to eq(:blocked)
    expect(diagnosis.infra_diagnostics).to eq({ "missing_path" => "/tmp/repo-beta" })
    expect(described_class.from_persisted_form(diagnosis.persisted_form)).to eq(diagnosis)
    expect(diagnosis).to be_frozen
  end

  it "deep-freezes nested infrastructure diagnostics" do
    diagnosis = described_class.new(
      task_ref: "A3-v2#3025",
      run_ref: "run-1",
      phase: :review,
      outcome: :blocked,
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: "A3-v2#3025",
        phase_ref: :review
      ),
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
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      ),
      expected_state: "runtime workspace available",
      observed_state: "repo-beta missing",
      failing_command: "codex exec --json -",
      diagnostic_summary: "review launch could not resolve runtime workspace",
      infra_diagnostics: { "worker_response_bundle" => { "diagnostics" => { "stderr" => ["boom"] } } }
    )

    expect do
      diagnosis.infra_diagnostics.fetch("worker_response_bundle").fetch("diagnostics")["stderr"] << "again"
    end.to raise_error(FrozenError)
  end
end
