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

  it "classifies blocked diagnosis and gives a user-facing remediation" do
    diagnosis = described_class.new(
      task_ref: "A2O#12",
      run_ref: "run-1",
      phase: :verification,
      outcome: :blocked,
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: "A2O#12",
        phase_ref: :verification
      ),
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: "A2O#12"
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A2O#12",
        owner_scope: :task,
        snapshot_version: "head456"
      ),
      expected_state: "verification commands pass",
      observed_state: "exit 1",
      failing_command: "commands/verify",
      diagnostic_summary: "commands/verify failed",
      infra_diagnostics: { "stderr" => "test failed" }
    )

    expect(diagnosis.error_category).to eq("verification_failed")
    expect(diagnosis.remediation_summary).to include("verification")
  end

  it "classifies dirty workspace failures before generic verification failures" do
    diagnosis = described_class.new(
      task_ref: "A2O#12",
      run_ref: "run-1",
      phase: :verification,
      outcome: :blocked,
      review_target: A3::Domain::ReviewTarget.new(base_commit: "base", head_commit: "head", task_ref: "A2O#12", phase_ref: :verification),
      source_descriptor: A3::Domain::SourceDescriptor.new(workspace_kind: :runtime_workspace, source_type: :detached_commit, ref: "head", task_ref: "A2O#12"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:app], verification_scope: [:app], ownership_scope: :task),
      artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "A2O#12", owner_scope: :task, snapshot_version: "head"),
      expected_state: "workspace is clean",
      observed_state: "slot app has changes but is not an edit target: [README.md]",
      failing_command: "publish_workspace_changes",
      diagnostic_summary: "slot app has changes but is not an edit target: [README.md]",
      infra_diagnostics: {}
    )

    expect(diagnosis.error_category).to eq("workspace_dirty")
    expect(diagnosis.remediation_summary).to include("commit")
  end

  it "does not classify review worker remediation diagnostics as verification failures" do
    diagnosis = described_class.new(
      task_ref: "A2O#12",
      run_ref: "run-1",
      phase: :review,
      outcome: :blocked,
      review_target: A3::Domain::ReviewTarget.new(base_commit: "base", head_commit: "head", task_ref: "A2O#12", phase_ref: :review),
      source_descriptor: A3::Domain::SourceDescriptor.new(workspace_kind: :runtime_workspace, source_type: :detached_commit, ref: "head", task_ref: "A2O#12"),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:app], verification_scope: [:app], ownership_scope: :task),
      artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: "A2O#12", owner_scope: :task, snapshot_version: "head"),
      expected_state: "review passes",
      observed_state: "worker blocked",
      failing_command: "review_worker",
      diagnostic_summary: "worker result JSON invalid",
      infra_diagnostics: {
        "worker_response_bundle" => {
          "diagnostics" => {
            "remediation" => "Check the worker result JSON."
          }
        }
      }
    )

    expect(diagnosis.error_category).to eq("executor_failed")
    expect(diagnosis.remediation_summary).to include("executor command")
  end
end
