# frozen_string_literal: true

RSpec.describe A3::Application::RunVerification do
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
      command_runner: command_runner,
      prepare_workspace: prepare_workspace,
      task_metrics_repository: task_metrics_repository
    )
  end

  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
  let(:task_metrics_repository) { A3::Infra::InMemoryTaskMetricsRepository.new }
  let(:integration_ref_readiness_checker) do
    instance_double(
      A3::Infra::IntegrationRefReadinessChecker,
      check: A3::Infra::IntegrationRefReadinessChecker::Result.new(ready: true, missing_slots: [], ref: "refs/heads/a2o/parent/A3-v2-3022")
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
  let(:command_runner) { instance_double("CommandRunner") }

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta],
      status: :verifying,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#3022"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
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
        verification_commands: ["commands/verify-all", "commands/gate-standard"],
        remediation_commands: ["commands/apply-remediation"],
        workspace_hook: "hooks/prepare-runtime.sh"
      ),
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only
      )
    )
  end

  let(:metrics_project_context) do
    A3::Domain::ProjectContext.new(
      surface: A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation/base.md",
        review_skill: "skills/review/base.md",
        verification_commands: ["commands/verify-all"],
        remediation_commands: [],
        metrics_collection_commands: ["commands/collect-metrics"],
        workspace_hook: nil
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

  it "records verification summary and advances on success" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace/repo-alpha")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/apply-remediation ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace/repo-beta")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/apply-remediation ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).verification_commands,
      workspace: prepared_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      worker_protocol_request: hash_including("command_intent" => "verification")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/verify-all ok; commands/gate-standard ok",
        diagnostics: {}
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:merging)
    expect(result.run.phase_records.last.verification_summary).to eq(
      "commands/apply-remediation ok; commands/apply-remediation ok; commands/verify-all ok; commands/gate-standard ok"
    )
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "commands/apply-remediation ok; commands/apply-remediation ok; commands/verify-all ok; commands/gate-standard ok",
      diagnostics: {}
    )
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      phase: :verification,
      verification_commands: ["commands/verify-all", "commands/gate-standard"],
      merge_target: :merge_to_parent
    )
    expect(result.run.terminal_outcome).to eq(:completed)
  end

  it "records blocked diagnosis and blocks the task on failure" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace/repo-alpha")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/apply-remediation ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace/repo-beta")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/apply-remediation ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).verification_commands,
      workspace: prepared_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      worker_protocol_request: hash_including("command_intent" => "verification")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: false,
        summary: "commands/gate-standard failed",
        failing_command: "commands/gate-standard",
        observed_state: "exit 1",
        diagnostics: { "stderr" => "boom" }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.terminal_outcome).to eq(:blocked)
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "commands/gate-standard failed",
      failing_command: "commands/gate-standard",
      observed_state: "exit 1",
      diagnostics: { "stderr" => "boom" }
    )
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      phase: :verification,
      verification_commands: ["commands/verify-all", "commands/gate-standard"]
    )
    expect(result.run.phase_records.last.blocked_diagnosis&.failing_command).to eq("commands/gate-standard")
  end

  it "collects task metrics after successful verification when configured" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(command_runner).to receive(:run).with(
      metrics_project_context.resolve_phase_runtime(task: task, phase: run.phase).verification_commands,
      workspace: prepared_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      worker_protocol_request: hash_including("command_intent" => "verification")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/verify-all ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      ["commands/collect-metrics"],
      workspace: prepared_workspace,
      env: {},
      task: task,
      run: run,
      command_intent: :metrics_collection
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/collect-metrics ok",
        diagnostics: {
          "stdout" => JSON.generate(
            "code_changes" => { "lines_added" => 10 },
            "tests" => { "passed_count" => 5 },
            "coverage" => { "line_percent" => 80.0 },
            "custom" => { "team" => "alpha" }
          )
        }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: metrics_project_context)

    expect(result.task.status).to eq(:merging)
    expect(task_metrics_repository.all.map(&:persisted_form)).to contain_exactly(
      hash_including(
        "task_ref" => task.ref,
        "parent_ref" => task.parent_ref,
        "code_changes" => { "lines_added" => 10 },
        "tests" => { "passed_count" => 5 },
        "coverage" => { "line_percent" => 80.0 },
        "custom" => { "team" => "alpha" }
      )
    )
    expect(result.run.phase_records.last.execution_record.diagnostics).to include(
      "metrics_collection" => { "collected" => true }
    )
  end

  it "records metrics collection errors without hiding successful verification" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(command_runner).to receive(:run).with(
      metrics_project_context.resolve_phase_runtime(task: task, phase: run.phase).verification_commands,
      workspace: prepared_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      worker_protocol_request: hash_including("command_intent" => "verification")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/verify-all ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      ["commands/collect-metrics"],
      workspace: prepared_workspace,
      env: {},
      task: task,
      run: run,
      command_intent: :metrics_collection
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/collect-metrics ok",
        diagnostics: { "stdout" => "not json" }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: metrics_project_context)

    expect(result.task.status).to eq(:merging)
    expect(task_metrics_repository.all).to eq([])
    expect(result.run.phase_records.last.execution_record.diagnostics.fetch("metrics_collection")).to include(
      "summary" => "metrics collection produced invalid JSON",
      "failing_command" => "metrics_collection"
    )
  end

  it "records invalid metrics payload shape without hiding successful verification" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(command_runner).to receive(:run).with(
      metrics_project_context.resolve_phase_runtime(task: task, phase: run.phase).verification_commands,
      workspace: prepared_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      worker_protocol_request: hash_including("command_intent" => "verification")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/verify-all ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      ["commands/collect-metrics"],
      workspace: prepared_workspace,
      env: {},
      task: task,
      run: run,
      command_intent: :metrics_collection
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/collect-metrics ok",
        diagnostics: { "stdout" => JSON.generate("not an object") }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: metrics_project_context)

    expect(result.task.status).to eq(:merging)
    expect(task_metrics_repository.all).to eq([])
    expect(result.run.phase_records.last.execution_record.diagnostics.fetch("metrics_collection")).to include(
      "summary" => "metrics collection produced invalid metrics payload",
      "failing_command" => "metrics_collection",
      "observed_state" => "task metrics payload must be a JSON object"
    )
  end

  it "records blocked diagnosis when slot-local remediation fails before verification" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace/repo-alpha")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: false,
        summary: "commands/apply-remediation failed",
        failing_command: "commands/apply-remediation",
        observed_state: "exit 200",
        diagnostics: { "stderr" => "boom" }
      )
    )
    expect(command_runner).not_to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/runtime_workspace/repo-beta")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    )
    expect(command_runner).not_to receive(:run).with(
      project_context.resolve_phase_runtime(task: task, phase: run.phase).verification_commands,
      workspace: prepared_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.terminal_outcome).to eq(:blocked)
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "commands/apply-remediation failed",
      failing_command: "commands/apply-remediation",
      observed_state: "exit 200",
      diagnostics: { "stderr" => "boom" }
    )
    expect(result.run.phase_records.last.blocked_diagnosis&.failing_command).to eq("commands/apply-remediation")
  end

  it "records parent verification against the integration branch and advances to merge" do
    parent_task = A3::Domain::Task.new(
      ref: "A3-v2#3022",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :verifying,
      current_run_ref: "run-parent-verification-1",
      child_refs: %w[A3-v2#3025 A3-v2#3026]
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-verification-1",
      task_ref: parent_task.ref,
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: parent_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "refs/heads/a2o/parent/A3-v2-3022",
        head_commit: "refs/heads/a2o/parent/A3-v2-3022",
        task_ref: parent_task.ref,
        phase_ref: :verification
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "refs/heads/a2o/parent/A3-v2-3022"
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
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: parent_task, phase: parent_run.phase).remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace/repo-alpha")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/apply-remediation ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: parent_task, phase: parent_run.phase).remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3022/runtime_workspace/repo-beta")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/apply-remediation ok"
      )
    )
    allow(command_runner).to receive(:run).with(
      project_context.resolve_phase_runtime(task: parent_task, phase: parent_run.phase).verification_commands,
      workspace: prepared_parent_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: anything,
      run: anything,
      worker_protocol_request: hash_including("command_intent" => "verification")
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "commands/verify-all ok; commands/gate-standard ok"
      )
    )

    result = use_case.call(task_ref: parent_task.ref, run_ref: parent_run.ref, project_context: project_context)

    expect(result.task.status).to eq(:merging)
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      task_kind: :parent,
      phase: :verification,
      merge_target: :merge_to_parent
    )
    expect(result.run.terminal_outcome).to eq(:completed)
  end
end
