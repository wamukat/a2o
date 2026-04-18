# frozen_string_literal: true

RSpec.describe A3::Domain::BlockedDiagnosisFactory do
  subject(:factory) { described_class.new }

  it "builds blocked diagnosis from task, run and execution result" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha]
    )
    run = A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
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
      )
    )
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "gate failed",
      diagnostics: { "stderr" => "boom" }
    )

    diagnosis = factory.call(
      task: task,
      run: run,
      execution: execution,
      expected_state: "verification commands pass",
      default_failing_command: "commands/gate-standard",
      extra_diagnostics: { "worker_response_bundle" => { "success" => false } }
    )

    expect(diagnosis.task_ref).to eq(task.ref)
    expect(diagnosis.run_ref).to eq(run.ref)
    expect(diagnosis.phase).to eq(:verification)
    expect(diagnosis.expected_state).to eq("verification commands pass")
    expect(diagnosis.failing_command).to eq("commands/gate-standard")
    expect(diagnosis.observed_state).to eq("verification failed")
    expect(diagnosis.infra_diagnostics).to include(
      "stderr" => "boom",
      "worker_response_bundle" => { "success" => false }
    )
  end
end
