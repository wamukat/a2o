# frozen_string_literal: true

RSpec.describe "phase execution strategies" do
  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      status: :in_progress,
      current_run_ref: "run-1",
      parent_ref: "A3-v2#3022"
    )
  end

  let(:implementation_run) do
    A3::Domain::Run.new(
      ref: "run-1",
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
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: "A3-v2#3022",
        owner_scope: :task,
        snapshot_version: "refs/heads/a2o/work/3025"
      )
    )
  end

  let(:runtime) do
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :single,
      phase: :implementation,
      implementation_skill: "skills/implementation/base.md",
      review_skill: "skills/review/base.md",
      verification_commands: ["commands/verify-all"],
      remediation_commands: ["commands/apply-remediation"],
      workspace_hook: "hooks/prepare-runtime.sh",
      merge_target: :merge_to_parent,
      merge_policy: :ff_only
    )
  end

  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace",
      source_descriptor: implementation_run.source_descriptor,
      slot_paths: {}
    )
  end
  let(:task_packet_builder) do
    instance_double("TaskPacketBuilder").tap do |builder|
      allow(builder).to receive(:call).with(task: task).and_return(
        A3::Domain::WorkerTaskPacket.new(
          ref: task.ref,
          external_task_id: 3025,
          kind: task.kind,
          edit_scope: task.edit_scope,
          verification_scope: task.verification_scope,
          parent_ref: task.parent_ref,
          child_refs: task.child_refs,
          title: "sample title",
          description: "sample description",
          status: "In progress",
          labels: %w[repo:alpha trigger:auto-implement]
        )
      )
    end
  end

  it "worker strategy preserves the structured response bundle in diagnostics" do
    worker_gateway = instance_double("WorkerGateway")
    strategy = A3::Application::WorkerPhaseExecutionStrategy.new(
      worker_gateway: worker_gateway,
      task_packet_builder: task_packet_builder
    )
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "review blocked",
      failing_command: "worker review",
      observed_state: "blocked_refresh_failure",
      diagnostics: { "stderr" => "refresh failed" },
      response_bundle: { "success" => false, "observed_state" => "blocked_refresh_failure" }
    )
    allow(worker_gateway).to receive(:run).and_return(execution)

    result = strategy.execute(task: task, run: implementation_run, runtime: runtime, workspace: workspace)

    expect(result.diagnostics).to eq(
      "stderr" => "refresh failed",
      "worker_response_bundle" => { "success" => false, "observed_state" => "blocked_refresh_failure" }
    )
    expect(strategy.blocked_expected_state).to eq("worker phase succeeds")
    expect(strategy.blocked_default_failing_command).to eq("worker_gateway")
    expect(strategy.verification_summary(result)).to be_nil
  end

  it "keeps workspace publication free of project remediation commands" do
    worker_gateway = instance_double("WorkerGateway")
    workspace_change_publisher = instance_double(A3::Infra::DisabledWorkspaceChangePublisher)
    strategy = A3::Application::WorkerPhaseExecutionStrategy.new(
      worker_gateway: worker_gateway,
      task_packet_builder: task_packet_builder,
      workspace_change_publisher: workspace_change_publisher
    )
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "implementation completed",
      response_bundle: { "changed_files" => { "repo_alpha" => ["keep.txt"] } }
    )
    publication = A3::Application::ExecutionResult.new(
      success: true,
      summary: "task fmt:apply ok; published workspace changes for repo_alpha",
      diagnostics: { "published_slots" => [{ "slot" => "repo_alpha" }] }
    )
    allow(worker_gateway).to receive(:run).and_return(execution)
    allow(workspace_change_publisher).to receive(:publish).and_return(publication)

    result = strategy.execute(task: task, run: implementation_run, runtime: runtime, workspace: workspace)

    expect(workspace_change_publisher).to have_received(:publish).with(
      run: implementation_run,
      workspace: workspace,
      execution: have_attributes(summary: "implementation completed"),
      remediation_commands: []
    )
    expect(result.summary).to include("published workspace changes for repo_alpha")
  end

  it "fails closed when a non-agent implementation would require Engine-side publication" do
    worker_gateway = instance_double("WorkerGateway")
    strategy = A3::Application::WorkerPhaseExecutionStrategy.new(
      worker_gateway: worker_gateway,
      task_packet_builder: task_packet_builder
    )
    allow(worker_gateway).to receive(:run).and_return(
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "implementation completed",
        response_bundle: { "changed_files" => { "repo_alpha" => ["keep.txt"] } }
      )
    )

    result = strategy.execute(task: task, run: implementation_run, runtime: runtime, workspace: workspace)

    expect(result).to have_attributes(
      success?: false,
      failing_command: "workspace_change_publication",
      observed_state: "engine_workspace_mutation_disabled"
    )
  end

  it "verification strategy exposes execution summary as verification summary and diagnostics on blocked" do
    command_runner = instance_double("CommandRunner")
    strategy = A3::Application::VerificationExecutionStrategy.new(command_runner: command_runner, task_packet_builder: task_packet_builder)
    runtime_without_remediation = A3::Domain::PhaseRuntimeConfig.new(
      task_kind: runtime.task_kind,
      repo_scope: runtime.repo_scope,
      phase: runtime.phase,
      implementation_skill: runtime.implementation_skill,
      review_skill: runtime.review_skill,
      verification_commands: runtime.verification_commands,
      remediation_commands: [],
      workspace_hook: runtime.workspace_hook,
      merge_target: runtime.merge_target,
      merge_policy: runtime.merge_policy
    )
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "commands/verify-all ok"
    )
    allow(command_runner).to receive(:run).and_return(execution)

    result = strategy.execute(task: task, run: implementation_run, runtime: runtime_without_remediation, workspace: workspace)

    expect(result).to eq(execution)
    expect(strategy.verification_summary(result)).to eq("commands/verify-all ok")
    expect(strategy.blocked_extra_diagnostics(result)).to eq({})
  end

  it "does not require an Engine workspace when verification is agent materialized" do
    command_runner = instance_double("CommandRunner")
    allow(command_runner).to receive(:agent_owned_workspace?).and_return(true)
    strategy = A3::Application::VerificationExecutionStrategy.new(command_runner: command_runner, task_packet_builder: task_packet_builder)

    expect(strategy.requires_workspace?).to eq(false)
  end

  it "verification remediation runs in each verification slot before workspace-level verification" do
    slot_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace",
      source_descriptor: implementation_run.source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-alpha",
        repo_beta: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-beta"
      }
    )
    command_runner = instance_double("CommandRunner")
    strategy = A3::Application::VerificationExecutionStrategy.new(command_runner: command_runner, task_packet_builder: task_packet_builder)
    remediation_execution = A3::Application::ExecutionResult.new(success: true, summary: "commands/apply-remediation ok")
    verification_execution = A3::Application::ExecutionResult.new(success: true, summary: "commands/verify-all ok")

    expect(command_runner).to receive(:run).with(
      runtime.remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-alpha")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: task,
      run: implementation_run,
      command_intent: :remediation,
      worker_protocol_request: hash_including(
        "command_intent" => "remediation",
        "slot_paths" => {
          "repo_alpha" => "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-alpha",
          "repo_beta" => "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-beta"
        }
      )
    ).ordered.and_return(remediation_execution)
    expect(command_runner).to receive(:run).with(
      runtime.remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-beta")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: task,
      run: implementation_run,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).ordered.and_return(remediation_execution)
    expect(command_runner).to receive(:run).with(
      runtime.verification_commands,
      workspace: slot_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: task,
      run: implementation_run,
      command_intent: :verification,
      worker_protocol_request: hash_including("command_intent" => "verification")
    ).ordered.and_return(verification_execution)

    result = strategy.execute(task: task, run: implementation_run, runtime: runtime, workspace: slot_workspace)

    expect(result.summary).to eq("commands/apply-remediation ok; commands/apply-remediation ok; commands/verify-all ok")
  end

  it "runs remediation once at the workspace root when the agent owns materialization" do
    slot_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace",
      source_descriptor: implementation_run.source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-alpha",
        repo_beta: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-beta"
      }
    )
    command_runner = instance_double("CommandRunner")
    allow(command_runner).to receive(:agent_owned_workspace?).and_return(true)
    strategy = A3::Application::VerificationExecutionStrategy.new(command_runner: command_runner, task_packet_builder: task_packet_builder)
    remediation_execution = A3::Application::ExecutionResult.new(success: true, summary: "commands/apply-remediation ok")
    verification_execution = A3::Application::ExecutionResult.new(success: true, summary: "commands/verify-all ok")

    expect(command_runner).to receive(:run).with(
      runtime.remediation_commands,
      workspace: slot_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: task,
      run: implementation_run,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).ordered.and_return(remediation_execution)
    expect(command_runner).to receive(:run).with(
      runtime.verification_commands,
      workspace: slot_workspace,
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: task,
      run: implementation_run,
      command_intent: :verification,
      worker_protocol_request: hash_including("command_intent" => "verification")
    ).ordered.and_return(verification_execution)

    result = strategy.execute(task: task, run: implementation_run, runtime: runtime, workspace: slot_workspace)

    expect(result.summary).to eq("commands/apply-remediation ok; commands/verify-all ok")
  end

  it "stops verification when slot-local remediation fails" do
    slot_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace",
      source_descriptor: implementation_run.source_descriptor,
      slot_paths: {
        repo_alpha: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-alpha",
        repo_beta: "/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-beta"
      }
    )
    command_runner = instance_double("CommandRunner")
    strategy = A3::Application::VerificationExecutionStrategy.new(command_runner: command_runner, task_packet_builder: task_packet_builder)
    remediation_failure = A3::Application::ExecutionResult.new(
      success: false,
      summary: "commands/apply-remediation failed",
      failing_command: "commands/apply-remediation",
      observed_state: "exit 200",
      diagnostics: { "stderr" => "boom" }
    )

    expect(command_runner).to receive(:run).with(
      runtime.remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-alpha")),
      env: hash_including("A2O_WORKER_REQUEST_PATH", "A2O_WORKSPACE_ROOT"),
      task: task,
      run: implementation_run,
      command_intent: :remediation,
      worker_protocol_request: hash_including("command_intent" => "remediation")
    ).ordered.and_return(remediation_failure)
    expect(command_runner).not_to receive(:run).with(
      runtime.remediation_commands,
      workspace: have_attributes(root_path: Pathname("/tmp/a3-v2/workspaces/A3-v2-3025/ticket_workspace/repo-beta")),
      env: anything,
      task: task,
      run: implementation_run,
      command_intent: :remediation,
      worker_protocol_request: anything
    )
    expect(command_runner).not_to receive(:run).with(runtime.verification_commands, workspace: slot_workspace, env: anything, task: task, run: implementation_run, command_intent: :verification, worker_protocol_request: anything)

    result = strategy.execute(task: task, run: implementation_run, runtime: runtime, workspace: slot_workspace)

    expect(result).to eq(remediation_failure)
  end

  it "merge strategy delegates to merge runner and exposes merge summary" do
    merge_runner = instance_double("MergeRunner")
    merge_plan = A3::Domain::MergePlan.new(
      task_ref: task.ref,
      run_ref: implementation_run.ref,
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a2o/work/3025"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/a2o/parent/A3-v2-3022"),
      merge_slots: [:repo_alpha],
      merge_policy: :ff_only
    )
    strategy = A3::Application::MergeExecutionStrategy.new(
      merge_runner: merge_runner,
      merge_plan: merge_plan
    )
    execution = A3::Application::ExecutionResult.new(success: true, summary: "merged ok")
    allow(merge_runner).to receive(:run).with(merge_plan, workspace: workspace).and_return(execution)

    result = strategy.execute(task: task, run: implementation_run, runtime: runtime, workspace: workspace)

    expect(result).to be(execution)
    expect(strategy.verification_summary(result)).to eq("merged ok")
    expect(strategy.blocked_expected_state).to eq("merge succeeds")
    expect(strategy.blocked_default_failing_command).to eq("merge")
  end
end
