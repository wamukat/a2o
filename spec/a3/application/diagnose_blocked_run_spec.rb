# frozen_string_literal: true

RSpec.describe A3::Application::DiagnoseBlockedRun do
  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      status: :blocked,
      parent_ref: "A3-v2#3022"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :detached_commit,
        ref: "head456",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head456"
      ),
      terminal_outcome: :blocked
    )
  end

  before do
    task_repository.save(task)
    run_repository.save(run)
  end

  it "builds a blocked diagnosis bundle from persisted evidence" do
    result = use_case.call(
      task_ref: task.ref,
      run_ref: run.ref,
      expected_state: "runtime workspace available",
      observed_state: "repo-beta missing",
      failing_command: "codex exec --json -",
      diagnostic_summary: "review launch could not resolve runtime workspace",
      infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
    )

    expect(result.task).to eq(task)
    expect(result.run.ref).to eq("run-1")
    expect(result.diagnosis.outcome).to eq(:blocked)
    expect(result.diagnosis.review_target).to eq(run.evidence.review_target)
    expect(result.run.phase_records.last.blocked_diagnosis).to eq(result.diagnosis)
  end

  it "fails fast when the persisted run is not blocked" do
    completed_run = run.complete(outcome: :completed)
    run_repository.save(completed_run)

    expect do
      use_case.call(
        task_ref: task.ref,
        run_ref: completed_run.ref,
        expected_state: "runtime workspace available",
        observed_state: "repo-beta missing",
        failing_command: "codex exec --json -",
        diagnostic_summary: "review launch could not resolve runtime workspace",
        infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
      )
    end.to raise_error(A3::Domain::ConfigurationError, /blocked run required/)
  end
end
