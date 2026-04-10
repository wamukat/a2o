# frozen_string_literal: true

RSpec.describe A3::Application::PhaseExecutionFlow do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:integration_ref_readiness_checker) do
    instance_double(
      A3::Infra::IntegrationRefReadinessChecker,
      check: A3::Infra::IntegrationRefReadinessChecker::Result.new(ready: true, missing_slots: [], ref: "refs/heads/a3/parent/A3-v2-3022")
    )
  end
  let(:register_completed_run) do
    A3::Application::RegisterCompletedRun.new(
      task_repository: task_repository,
      run_repository: run_repository,
      plan_next_phase: A3::Application::PlanNextPhase.new,
      integration_ref_readiness_checker: integration_ref_readiness_checker
    )
  end
  let(:prepare_workspace) { instance_double(A3::Application::PrepareWorkspace) }
  let(:strategy) { instance_double("ExecutionStrategy") }

  subject(:flow) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      register_completed_run: register_completed_run,
      prepare_workspace: prepare_workspace
    )
  end

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
      status: :in_progress,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#3022"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a3/work/3025",
        head_commit: "refs/heads/a3/work/3025",
        task_ref: task.ref,
        phase_ref: :implementation
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "refs/heads/a3/work/3025"
      )
    )
  end

  let(:project_context) do
    A3::Domain::ProjectContext.new(
      surface: A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation/base.md",
        review_skill: "skills/review/base.md",
        verification_commands: ["commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        workspace_hook: "hooks/prepare-runtime.sh"
      ),
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only
      )
    )
  end

  before do
    task_repository.save(task)
    run_repository.save(run)
  end

  it "prepares, executes, and completes a successful phase" do
    prepared_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/work",
      source_descriptor: run.source_descriptor,
      slot_paths: { repo_alpha: "/tmp/work/repo-alpha" }
    )
    execution = A3::Application::ExecutionResult.new(success: true, summary: "completed")

    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(strategy).to receive(:execute).and_return(execution)
    allow(strategy).to receive(:verification_summary).with(execution).and_return(nil)
    allow(strategy).to receive(:blocked_expected_state).and_return("phase succeeds")
    allow(strategy).to receive(:blocked_default_failing_command).and_return("adapter")
    allow(strategy).to receive(:blocked_extra_diagnostics).with(execution).and_return(execution.diagnostics)

    result = flow.call(
      task_ref: task.ref,
      run_ref: run.ref,
      project_context: project_context,
      strategy: strategy
    )

    expect(result.task.status).to eq(:verifying)
    expect(result.workspace).to eq(prepared_workspace)
    expect(strategy).to have_received(:execute).with(
      task: task,
      run: run,
      runtime: project_context.resolve_phase_runtime(task: task, phase: run.phase),
      workspace: prepared_workspace
    )
  end

  it "persists implementation-side review evidence from the worker response bundle" do
    prepared_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/work",
      source_descriptor: run.source_descriptor,
      slot_paths: { repo_alpha: "/tmp/work/repo-alpha" }
    )
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "completed",
      response_bundle: {
        "review_disposition" => {
          "kind" => "completed",
          "repo_scope" => "repo_alpha",
          "summary" => "No findings",
          "description" => "Implementation finished and final self-review found no outstanding issues.",
          "finding_key" => "completed-no-findings"
        }
      }
    )

    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(strategy).to receive(:execute).and_return(execution)
    allow(strategy).to receive(:verification_summary).with(execution).and_return(nil)
    allow(strategy).to receive(:blocked_expected_state).and_return("phase succeeds")
    allow(strategy).to receive(:blocked_default_failing_command).and_return("adapter")
    allow(strategy).to receive(:blocked_extra_diagnostics).with(execution).and_return(execution.diagnostics)

    result = flow.call(
      task_ref: task.ref,
      run_ref: run.ref,
      project_context: project_context,
      strategy: strategy
    )

    expect(result.run.phase_records.last.execution_record.review_disposition).to eq(
      "kind" => "completed",
      "repo_scope" => "repo_alpha",
      "summary" => "No findings",
      "description" => "Implementation finished and final self-review found no outstanding issues.",
      "finding_key" => "completed-no-findings"
    )
  end

  it "records blocked failure evidence through the shared flow" do
    prepared_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/work",
      source_descriptor: run.source_descriptor,
      slot_paths: { repo_alpha: "/tmp/work/repo-alpha" }
    )
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "failed",
      failing_command: "adapter",
      observed_state: "exit 1",
      diagnostics: { "stderr" => "boom" }
    )

    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(strategy).to receive(:execute).and_return(execution)
    allow(strategy).to receive(:verification_summary).with(execution).and_return(nil)
    allow(strategy).to receive(:blocked_expected_state).and_return("phase succeeds")
    allow(strategy).to receive(:blocked_default_failing_command).and_return("adapter")
    allow(strategy).to receive(:blocked_extra_diagnostics).with(execution).and_return(execution.diagnostics)

    result = flow.call(
      task_ref: task.ref,
      run_ref: run.ref,
      project_context: project_context,
      strategy: strategy
    )

    expect(result.task.status).to eq(:blocked)
    expect(result.run.phase_records.last.blocked_diagnosis&.expected_state).to eq("phase succeeds")
    expect(result.run.phase_records.last.execution_record.runtime_snapshot.phase).to eq(:implementation)
  end
end
