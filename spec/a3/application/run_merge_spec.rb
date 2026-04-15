# frozen_string_literal: true

RSpec.describe A3::Application::RunMerge do
  let(:prepare_workspace) { instance_double(A3::Application::PrepareWorkspace) }
  let(:prepared_workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace",
      source_descriptor: run.source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace/repo-alpha",
        repo_beta: "/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace/repo-beta"
      }
    )
  end

  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      register_completed_run: register_completed_run,
      build_merge_plan: build_merge_plan,
      merge_runner: merge_runner,
      prepare_workspace: prepare_workspace
    )
  end

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
  let(:build_merge_plan) do
    A3::Application::BuildMergePlan.new(
      task_repository: task_repository,
      run_repository: run_repository
    )
  end
  let(:merge_runner) { instance_double("MergeRunner") }

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      status: :merging,
      current_run_ref: "run-merge-1",
      parent_ref: "A3-v2#3022"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-merge-1",
      task_ref: task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/work/3025",
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
        policy: :ff_only,
        target_ref: "refs/heads/feature/prototype"
      )
    )
  end

  before do
    task_repository.save(task)
    run_repository.save(run)
  end

  it "records merge summary and completes on success" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(merge_runner).to receive(:run).with(
      an_instance_of(A3::Domain::MergePlan),
      workspace: prepared_workspace
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "merged refs/heads/a3/work/3025 into refs/heads/a3/parent/A3-v2#3022"
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:done)
    expect(result.run.phase_records.last.verification_summary).to include("merged refs/heads/a3/work/3025")
    expect(result.run.phase_records.last.execution_record&.summary).to include("merged refs/heads/a3/work/3025")
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      phase: :merge,
      merge_target: :merge_to_parent,
      merge_policy: :ff_only
    )
    expect(result.run.terminal_outcome).to eq(:completed)
  end

  it "records blocked diagnosis on merge failure" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(merge_runner).to receive(:run).with(
      an_instance_of(A3::Domain::MergePlan),
      workspace: prepared_workspace
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: false,
        summary: "merge failed",
        failing_command: "git merge --ff-only refs/heads/a3/work/3025",
        observed_state: "non-fast-forward",
        diagnostics: { "stderr" => "fatal: not possible" }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "merge failed",
      failing_command: "git merge --ff-only refs/heads/a3/work/3025",
      observed_state: "non-fast-forward",
      diagnostics: { "stderr" => "fatal: not possible" }
    )
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      phase: :merge,
      merge_target: :merge_to_parent
    )
    expect(result.run.phase_records.last.blocked_diagnosis&.observed_state).to eq("non-fast-forward")
  end

  it "keeps recoverable merge conflicts retryable for the merge recovery lane" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(merge_runner).to receive(:run).with(
      an_instance_of(A3::Domain::MergePlan),
      workspace: prepared_workspace
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: false,
        summary: "merge conflicted",
        failing_command: "agent_merge_job",
        observed_state: "merge_recovery_candidate",
        diagnostics: {
          "merge_recovery" => {
            "required" => true,
            "conflict_files" => ["docs/conflict.md"]
          }
        },
        response_bundle: {
          "merge_recovery_required" => true,
          "merge_recovery" => {
            "required" => true,
            "conflict_files" => ["docs/conflict.md"]
          }
        }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:merging)
    expect(result.run.terminal_outcome).to eq(:retryable)
    expect(result.run.phase_records.last.blocked_diagnosis).to be_nil
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      observed_state: "merge_recovery_candidate"
    )
  end

  it "records parent merge against the integration branch and completes to done" do
    parent_task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :merging,
      current_run_ref: "run-parent-merge-1",
      child_refs: %w[A3-v2#3025 A3-v2#3026]
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-merge-1",
      task_ref: parent_task.ref,
      phase: :merge,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: parent_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a3/parent/A3-v2-3022",
        head_commit: "refs/heads/a3/parent/A3-v2-3022",
        task_ref: parent_task.ref,
        phase_ref: :merge
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "refs/heads/a3/parent/A3-v2-3022"
      )
    )
    task_repository.save(parent_task)
    run_repository.save(parent_run)

    prepared_parent_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace",
      source_descriptor: parent_run.source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace/repo-alpha",
        repo_beta: "/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace/repo-beta"
      }
    )

    allow(prepare_workspace).to receive(:call).with(
      task: parent_task,
      phase: parent_run.phase,
      source_descriptor: parent_run.source_descriptor,
      scope_snapshot: parent_run.scope_snapshot,
      artifact_owner: parent_run.artifact_owner,
      bootstrap_marker: "hooks/prepare-runtime.sh"
    ).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_parent_workspace)
    )
    allow(merge_runner).to receive(:run).with(
      an_instance_of(A3::Domain::MergePlan),
      workspace: prepared_parent_workspace
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "merged refs/heads/a3/parent/A3-v2-3022 into refs/heads/live/main"
      )
    )

    result = use_case.call(task_ref: parent_task.ref, run_ref: parent_run.ref, project_context: A3::Domain::ProjectContext.new(
      surface: project_context.surface,
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_live,
        policy: :ff_or_merge,
        target_ref: "refs/heads/live/main"
      )
    ))

    expect(result.task.status).to eq(:done)
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      task_kind: :parent,
      phase: :merge,
      merge_target: :merge_to_live
    )
    expect(result.run.terminal_outcome).to eq(:completed)
  end

  it "skips Engine workspace preparation when the merge runner is agent-owned" do
    agent_merge_runner = instance_double("AgentMergeRunner", agent_owned?: true)
    use_case = described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      register_completed_run: register_completed_run,
      build_merge_plan: build_merge_plan,
      merge_runner: agent_merge_runner,
      prepare_workspace: prepare_workspace
    )
    expect(prepare_workspace).not_to receive(:call)
    allow(agent_merge_runner).to receive(:run).with(
      an_instance_of(A3::Domain::MergePlan),
      workspace: an_instance_of(A3::Domain::PreparedWorkspace)
    ).and_return(
      A3::Application::ExecutionResult.new(success: true, summary: "agent merged ok")
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:done)
    expect(result.run.phase_records.last.execution_record&.summary).to eq("agent merged ok")
  end
end
