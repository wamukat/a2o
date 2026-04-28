# frozen_string_literal: true

RSpec.describe A3::Application::RunWorkerPhase do
  let(:task_repository) { A3::Infra::InMemoryTaskRepository.new }
  let(:run_repository) { A3::Infra::InMemoryRunRepository.new }
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
  let(:prepare_workspace) { instance_double(A3::Application::PrepareWorkspace) }
  let(:worker_gateway) { instance_double("WorkerGateway") }
  let(:task_packet_builder) { ->(task:) { { "task_ref" => task.ref } } }
  let(:workspace_change_publisher) do
    instance_double(
      "WorkspaceChangePublisher",
      publish: A3::Application::ExecutionResult.new(success: true, summary: "no workspace changes to publish", diagnostics: { "published_slots" => [] })
    )
  end

  subject(:use_case) do
    described_class.new(
      task_repository: task_repository,
      run_repository: run_repository,
      register_completed_run: register_completed_run,
      prepare_workspace: prepare_workspace,
      worker_gateway: worker_gateway,
      task_packet_builder: task_packet_builder,
      workspace_change_publisher: workspace_change_publisher
    )
  end

  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_progress,
      current_run_ref: "run-impl-1",
      parent_ref: "A3-v2#3022"
    )
  end

  let(:run) do
    A3::Domain::Run.new(
      ref: "run-impl-1",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
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
  end

  let(:prepared_workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace",
      source_descriptor: run.source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-alpha",
        repo_beta: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-beta"
      }
    )
  end

  let(:review_task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3026",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-review-1",
      child_refs: ["A3-v2#3030", "A3-v2#3031"]
    )
  end

  let(:review_run) do
    A3::Domain::Run.new(
      ref: "run-review-1",
      task_ref: review_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3026",
        task_ref: review_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base789",
        head_commit: "head999",
        task_ref: review_task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3026",
        owner_scope: :parent,
        snapshot_version: "head999"
      )
    )
  end

  let(:review_workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3026/runtime_workspace",
      source_descriptor: review_run.source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3026/runtime_workspace/repo-alpha",
        repo_beta: "/tmp/a3-v2/workspaces/A3-v2-3026/runtime_workspace/repo-beta"
      }
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
    task_repository.save(review_task)
    run_repository.save(review_run)
  end

  it "runs implementation through the worker gateway and advances to verification" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(worker_gateway).to receive(:run).with(
      hash_including(
        skill: "skills/implementation/base.md",
        workspace: prepared_workspace,
        task: task,
        run: run,
        phase_runtime: project_context.resolve_phase_runtime(task: task, phase: run.phase),
        task_packet: { "task_ref" => task.ref }
      )
    ).and_return(
      A3::Application::ExecutionResult.new(success: true, summary: "implementation completed")
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:verifying)
    expect(result.run.terminal_outcome).to eq(:completed)
    expect(result.workspace).to eq(prepared_workspace)
    expect(result.run.phase_records.last.verification_summary).to be_nil
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "implementation completed",
      failing_command: nil,
      observed_state: nil,
      diagnostics: {}
    )
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      phase: :implementation,
      implementation_skill: "skills/implementation/base.md",
      merge_target: :merge_to_parent
    )
  end

  it "passes the latest review rework feedback into the retried implementation request" do
    review_rework_run = A3::Domain::Run.new(
      ref: "run-review-rework-1",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: run.scope_snapshot,
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base123",
        head_commit: "head456",
        task_ref: task.ref,
        phase_ref: :review
      ),
      artifact_owner: run.artifact_owner,
      terminal_outcome: :rework
    ).append_phase_evidence(
      phase: :review,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a2o/work/3025",
        task_ref: task.ref
      ),
      scope_snapshot: run.scope_snapshot,
      execution_record: A3::Domain::PhaseExecutionRecord.new(
        summary: "Review found missing assertion coverage.",
        failing_command: nil,
        observed_state: "Only the happy path is asserted.",
        diagnostics: {
          "worker_response_bundle" => {
            "success" => false,
            "summary" => "Review found missing assertion coverage.",
            "observed_state" => "Only the happy path is asserted.",
            "rework_required" => true
          }
        }
      )
    )
    run_repository.save(review_rework_run)
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(worker_gateway).to receive(:run).with(
      hash_including(
        skill: "skills/implementation/base.md",
        task: task,
        run: run,
        prior_review_feedback: hash_including(
          "run_ref" => "run-review-rework-1",
          "phase" => "review",
          "summary" => "Review found missing assertion coverage.",
          "observed_state" => "Only the happy path is asserted.",
          "worker_response_bundle" => hash_including("rework_required" => true)
        )
      )
    ).and_return(
      A3::Application::ExecutionResult.new(success: true, summary: "implementation reworked")
    )

    use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(worker_gateway).to have_received(:run)
  end

  it "skips Engine workspace preparation when the worker gateway owns workspace materialization" do
    allow(worker_gateway).to receive(:agent_owned_workspace?).and_return(true)
    allow(worker_gateway).to receive(:agent_owned_publication?).and_return(true)
    expect(prepare_workspace).not_to receive(:call)
    allow(worker_gateway).to receive(:run).with(
      hash_including(
        skill: "skills/implementation/base.md",
        workspace: have_attributes(workspace_kind: :ticket_workspace, slot_paths: {}),
        task: task,
        run: run,
        phase_runtime: project_context.resolve_phase_runtime(task: task, phase: run.phase),
        task_packet: { "task_ref" => task.ref }
      )
    ).and_return(
      A3::Application::ExecutionResult.new(success: true, summary: "agent implementation completed")
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:verifying)
    expect(result.run.terminal_outcome).to eq(:completed)
    expect(result.workspace.slot_paths).to eq({})
    expect(result.run.phase_records.last.execution_record&.summary).to eq("agent implementation completed")
  end

  it "records blocked diagnosis when the worker gateway fails" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(worker_gateway).to receive(:run).and_return(
      A3::Application::ExecutionResult.new(
        success: false,
        summary: "review policy failed",
        failing_command: "codex exec --json -",
        observed_state: "worker exit 1",
        diagnostics: { "stderr" => "boom" }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "review policy failed",
      failing_command: "codex exec --json -",
      observed_state: "worker exit 1",
      diagnostics: { "stderr" => "boom" }
    )
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      phase: :implementation,
      implementation_skill: "skills/implementation/base.md"
    )
    expect(result.run.phase_records.last.blocked_diagnosis&.failing_command).to eq("codex exec --json -")
  end

  it "preserves the structured worker result bundle on blocked diagnosis infra diagnostics" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(worker_gateway).to receive(:run).and_return(
      A3::Application::ExecutionResult.new(
        success: false,
        summary: "review blocked",
        failing_command: "worker review",
        observed_state: "blocked_refresh_failure",
        diagnostics: { "stderr" => "refresh failed" },
        response_bundle: {
          "success" => false,
          "summary" => "review blocked",
          "failing_command" => "worker review",
          "observed_state" => "blocked_refresh_failure"
        }
      )
    )

    result = use_case.call(task_ref: review_task.ref, run_ref: review_run.ref, project_context: project_context)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.phase_records.last.execution_record&.diagnostics).to eq(
      "stderr" => "refresh failed",
      "worker_response_bundle" => {
        "success" => false,
        "summary" => "review blocked",
        "failing_command" => "worker review",
        "observed_state" => "blocked_refresh_failure"
      }
    )
    expect(result.run.phase_records.last.execution_record.runtime_snapshot).to have_attributes(
      phase: :review,
      review_skill: "skills/review/base.md"
    )
    expect(result.run.phase_records.last.blocked_diagnosis&.infra_diagnostics).to eq({})
  end

  it "connects worker result schema failures to blocked phase outcome diagnostics" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(worker_gateway).to receive(:run).and_return(
      A3::Application::ExecutionResult.new(
        success: false,
        summary: "worker result schema invalid",
        failing_command: "worker_result_schema",
        observed_state: "invalid_worker_result",
        diagnostics: { "validation_errors" => ["failing_command must be a string when success is false"] },
        response_bundle: {
          "success" => false,
          "summary" => "review blocked",
          "observed_state" => "blocked_refresh_failure"
        }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "worker result schema invalid",
      failing_command: "worker_result_schema",
      observed_state: "invalid_worker_result"
    )
    expect(result.run.phase_records.last.blocked_diagnosis).to have_attributes(
      failing_command: "worker_result_schema",
      observed_state: "invalid_worker_result",
      diagnostic_summary: "worker result schema invalid"
    )
    expect(result.run.phase_records.last.blocked_diagnosis.infra_diagnostics).to include(
      "validation_errors" => ["failing_command must be a string when success is false"],
      "worker_response_bundle" => {
        "success" => false,
        "summary" => "review blocked",
        "observed_state" => "blocked_refresh_failure"
      }
    )
  end

  it "connects worker request-result mismatches to blocked phase diagnostics" do
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: prepared_workspace)
    )
    allow(worker_gateway).to receive(:run).and_return(
      A3::Application::ExecutionResult.new(
        success: false,
        summary: "worker result schema invalid",
        failing_command: "worker_result_schema",
        observed_state: "invalid_worker_result",
        diagnostics: {
          "validation_errors" => [
            "run_ref must match the worker request",
            "phase must match the worker request"
          ]
        },
        response_bundle: {
          "task_ref" => task.ref,
          "run_ref" => "run-other",
          "phase" => "review",
          "success" => false,
          "summary" => "review blocked",
          "failing_command" => "worker review",
          "observed_state" => "blocked_refresh_failure"
        }
      )
    )

    result = use_case.call(task_ref: task.ref, run_ref: run.ref, project_context: project_context)

    expect(result.task.status).to eq(:blocked)
    expect(result.run.phase_records.last.execution_record).to have_attributes(
      summary: "worker result schema invalid",
      failing_command: "worker_result_schema",
      observed_state: "invalid_worker_result"
    )
    expect(result.run.phase_records.last.blocked_diagnosis).to have_attributes(
      failing_command: "worker_result_schema",
      observed_state: "invalid_worker_result"
    )
    expect(result.run.phase_records.last.blocked_diagnosis.infra_diagnostics).to include(
      "validation_errors" => [
        "run_ref must match the worker request",
        "phase must match the worker request"
      ],
      "worker_response_bundle" => {
        "task_ref" => task.ref,
        "run_ref" => "run-other",
        "phase" => "review",
        "success" => false,
        "summary" => "review blocked",
        "failing_command" => "worker review",
        "observed_state" => "blocked_refresh_failure"
      }
    )
  end

  it "runs review through the worker gateway with review skill and runtime workspace" do
    allow(prepare_workspace).to receive(:call).with(
      task: review_task,
      phase: review_run.phase,
      source_descriptor: review_run.source_descriptor,
      scope_snapshot: review_run.scope_snapshot,
      artifact_owner: review_run.artifact_owner,
      bootstrap_marker: "hooks/prepare-runtime.sh"
    ).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: review_workspace)
    )
    allow(worker_gateway).to receive(:run).with(
      hash_including(
        skill: "skills/review/base.md",
        workspace: review_workspace,
        task: review_task,
        run: review_run,
        phase_runtime: project_context.resolve_phase_runtime(task: review_task, phase: review_run.phase),
        task_packet: { "task_ref" => review_task.ref }
      )
    ).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "review completed",
        response_bundle: {
          "review_disposition" => {
            "kind" => "completed",
            "repo_scope" => "repo_alpha",
            "summary" => "No findings",
            "description" => "Parent review completed without outstanding findings.",
            "finding_key" => "completed-no-findings"
          }
        }
      )
    )

    result = use_case.call(task_ref: review_task.ref, run_ref: review_run.ref, project_context: project_context)

    expect(result.task.status).to eq(:verifying)
    expect(result.run.terminal_outcome).to eq(:completed)
    expect(result.workspace).to eq(review_workspace)
    expect(result.run.phase_records.last.execution_record&.summary).to eq("review completed")
    expect(result.run.phase_records.last.execution_record&.review_disposition).to include(
      "kind" => "completed",
      "finding_key" => "completed-no-findings"
    )
  end

  it "runs a child review rerun through the worker gateway" do
    child_review_task = A3::Domain::Task.new(
      ref: "A3-v2#3099",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_review,
      current_run_ref: "run-review-child-1",
      parent_ref: "A3-v2#3022"
    )
    child_review_run = A3::Domain::Run.new(
      ref: "run-review-child-1",
      task_ref: child_review_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :integration_record,
        ref: "refs/heads/a2o/work/3099",
        task_ref: child_review_task.ref
      ),
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :task
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base3099",
        head_commit: "head3099",
        task_ref: child_review_task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "head3099"
      )
    )
    task_repository.save(child_review_task)
    run_repository.save(child_review_run)
    child_review_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3099/runtime_workspace",
      source_descriptor: child_review_run.source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3099/runtime_workspace/repo-alpha",
        repo_beta: "/tmp/a3-v2/workspaces/A3-v2-3099/runtime_workspace/repo-beta"
      }
    )
    allow(prepare_workspace).to receive(:call).and_return(
      A3::Application::PrepareWorkspace::Result.new(workspace: child_review_workspace)
    )
    allow(worker_gateway).to receive(:run).and_return(
      A3::Application::ExecutionResult.new(success: true, summary: "child review completed")
    )

    result = use_case.call(task_ref: child_review_task.ref, run_ref: child_review_run.ref, project_context: project_context)

    expect(result.task.status).to eq(:verifying)
    expect(worker_gateway).to have_received(:run)
  end
end
