require "json"
require "spec_helper"
require "tmpdir"

RSpec.describe A3::Infra::LocalWorkerGateway do
  let(:command_runner) { instance_double(A3::Infra::LocalCommandRunner) }
  let(:tmpdir) { Dir.mktmpdir("a3-v2-worker-gateway") }
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: Pathname(tmpdir).join("workspace"),
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :runtime_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/sample",
        task_ref: "A3-v2#3028"
      ),
      slot_paths: {
        repo_beta: Pathname(tmpdir).join("workspace", "repo-beta")
      }
    )
  end
  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3028",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta]
    )
  end
  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :runtime_workspace,
      source_descriptor: workspace.source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :child
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base-1",
        head_commit: "head-1",
        task_ref: task.ref,
        phase_ref: :implementation
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :child,
        snapshot_version: "head-1"
      )
    )
  end
  let(:task_packet) do
    A3::Domain::WorkerTaskPacket.new(
      ref: task.ref,
      external_task_id: 3028,
      kind: task.kind,
      edit_scope: task.edit_scope,
      verification_scope: task.verification_scope,
      parent_ref: task.parent_ref,
      child_refs: task.child_refs,
      title: "Migrate persistence from JDBC to MyBatis",
      description: "Replace the JDBC implementation with a MyBatis-backed one.",
      status: "In progress",
      labels: %w[repo:alpha trigger:auto-implement]
    )
  end
  let(:phase_runtime) do
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :ui_app,
      phase: :implementation,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash
    )
  end

  before do
    FileUtils.mkdir_p(workspace.root_path)
    FileUtils.mkdir_p(workspace.slot_paths.fetch(:repo_beta))
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it "delegates the skill command to the command runner in the prepared workspace" do
    result = A3::Application::ExecutionResult.new(success: true, summary: "ok")
    gateway = described_class.new(command_runner: command_runner)

    expect(command_runner).to receive(:run).with(
      ["task implementation"],
      workspace: workspace,
      env: {
        "A3_WORKER_REQUEST_PATH" => workspace.root_path.join(".a3", "worker-request.json").to_s,
        "A3_WORKER_RESULT_PATH" => workspace.root_path.join(".a3", "worker-result.json").to_s,
        "A3_WORKSPACE_ROOT" => workspace.root_path.to_s
      }
    ) do
      request_path = workspace.root_path.join(".a3", "worker-request.json")
      expect(request_path).to exist

      request = JSON.parse(request_path.read)
      expect(request).to include(
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "implementation",
        "skill" => "task implementation",
        "workspace_kind" => "runtime_workspace"
      )
      expect(request.fetch("source_descriptor")).to include(
        "workspace_kind" => "runtime_workspace",
        "source_type" => "branch_head",
        "ref" => "refs/heads/a3/work/sample"
      )
      expect(request.fetch("slot_paths")).to include(
        "repo_beta" => workspace.slot_paths.fetch(:repo_beta).to_s
      )
      expect(request.fetch("task_packet")).to include(
        "ref" => task.ref,
        "external_task_id" => 3028,
        "title" => "Migrate persistence from JDBC to MyBatis",
        "description" => "Replace the JDBC implementation with a MyBatis-backed one.",
        "labels" => %w[repo:alpha trigger:auto-implement]
      )
      expect(request.fetch("phase_runtime")).to include(
        "task_kind" => "child",
        "repo_scope" => "ui_app",
        "phase" => "implementation",
        "workspace_hook" => "bootstrap",
        "implementation_skill" => "task implementation",
        "review_skill" => "task review",
        "verification_commands" => [],
        "remediation_commands" => [],
        "merge_target" => "merge_to_parent",
        "merge_policy" => "squash"
      )
      expect(request.fetch("phase_runtime")).to eq(phase_runtime.worker_request_form)

      result
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution).to eq(result)
  end

  it "can execute an explicit worker command while preserving skill in the request payload" do
    result = A3::Application::ExecutionResult.new(success: true, summary: "ok")
    gateway = described_class.new(
      command_runner: command_runner,
      worker_command: "ruby",
      worker_command_args: ["scripts/a3/a3_direct_canary_worker.rb"]
    )

    expect(command_runner).to receive(:run).with(
      ["ruby scripts/a3/a3_direct_canary_worker.rb"],
      workspace: workspace,
      env: {
        "A3_WORKER_REQUEST_PATH" => workspace.root_path.join(".a3", "worker-request.json").to_s,
        "A3_WORKER_RESULT_PATH" => workspace.root_path.join(".a3", "worker-result.json").to_s,
        "A3_WORKSPACE_ROOT" => workspace.root_path.to_s
      }
    ) do
      request = JSON.parse(workspace.root_path.join(".a3", "worker-request.json").read)
      expect(request.fetch("skill")).to eq("task implementation")
      result
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution).to eq(result)
  end

  it "returns the command runner failure result unchanged" do
    result = A3::Application::ExecutionResult.new(
      success: false,
      summary: "task implementation failed",
      failing_command: "task implementation",
      observed_state: "exit 1",
      diagnostics: { "stderr" => "boom" }
    )
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do |_commands, workspace:, env:|
      expect(workspace.root_path.join(".a3", "worker-request.json")).to exist
      expect(env).to include(
        "A3_WORKER_REQUEST_PATH" => workspace.root_path.join(".a3", "worker-request.json").to_s,
        "A3_WORKSPACE_ROOT" => workspace.root_path.to_s
      )
      result
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution).to eq(result)
  end

  it "prefers a structured worker result bundle over the command runner exit result" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    bundle = {
      "success" => false,
      "summary" => "review blocked",
      "failing_command" => "worker review",
      "observed_state" => "blocked_refresh_failure",
      "rework_required" => false,
      "diagnostics" => { "stderr" => "refresh failed" }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do |_commands, workspace:, env:|
      expect(env).to include(
        "A3_WORKER_REQUEST_PATH" => workspace.root_path.join(".a3", "worker-request.json").to_s,
        "A3_WORKER_RESULT_PATH" => result_path.to_s,
        "A3_WORKSPACE_ROOT" => workspace.root_path.to_s
      )
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("review blocked")
    expect(execution.failing_command).to eq("worker review")
    expect(execution.observed_state).to eq("blocked_refresh_failure")
    expect(execution.diagnostics).to eq("stderr" => "refresh failed")
  end

  it "preserves review rework hints from the worker response bundle" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    bundle = {
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "implementation",
      "success" => false,
      "summary" => "review found follow-up work",
      "failing_command" => "review_worker",
      "observed_state" => "review_findings",
      "rework_required" => true
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(success: true, summary: "command runner succeeded")
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.rework_required?).to be(true)
  end

  it "accepts review findings with nil failing_command when rework is required" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    bundle = {
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => run.phase.to_s,
      "success" => false,
      "summary" => "review found follow-up work",
      "failing_command" => nil,
      "observed_state" => "review_findings",
      "rework_required" => true
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(success: true, summary: "command runner succeeded")
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.rework_required?).to be(true)
    expect(execution.response_bundle).to eq(bundle)
  end

  it "accepts changed_files in a successful worker result bundle" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    File.write(workspace.slot_paths.fetch(:repo_beta).join("src-main.rb"), "changed\n")
    bundle = {
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "implementation",
      "success" => true,
      "summary" => "implemented",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => { "repo_beta" => ["src/main.rb"] }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(true)
    expected_without_changed_files = bundle.dup
    expected_without_changed_files.delete("changed_files")
    expect(execution.response_bundle).to include(expected_without_changed_files)
    expect(execution.response_bundle.fetch("changed_files")).to eq({})
  end

  it "canonicalizes implementation changed_files from the actual workspace diff" do
    ticket_run = A3::Domain::Run.new(
      ref: run.ref,
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :ticket_workspace,
      source_descriptor: A3::Domain::SourceDescriptor.new(
        workspace_kind: :ticket_workspace,
        source_type: :branch_head,
        ref: "refs/heads/a3/work/sample",
        task_ref: task.ref
      ),
      scope_snapshot: run.scope_snapshot,
      review_target: run.evidence.review_target,
      artifact_owner: run.artifact_owner
    )
    workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :ticket_workspace,
      root_path: Pathname(tmpdir).join("ticket-workspace-root"),
      source_descriptor: ticket_run.source_descriptor,
      slot_paths: {
        repo_beta: Pathname(tmpdir).join("ticket-workspace-root", "repo-beta")
      }
    )
    slot_path = workspace.slot_paths.fetch(:repo_beta)
    FileUtils.mkdir_p(slot_path)
    system("git", "-C", slot_path.to_s, "init", exception: true, out: File::NULL, err: File::NULL)
    system("git", "-C", slot_path.to_s, "config", "user.name", "Spec", exception: true)
    system("git", "-C", slot_path.to_s, "config", "user.email", "spec@example.com", exception: true)
    File.write(slot_path.join("keep.txt"), "before\n")
    system("git", "-C", slot_path.to_s, "add", "keep.txt", exception: true)
    system("git", "-C", slot_path.to_s, "commit", "-m", "init", exception: true, out: File::NULL, err: File::NULL)
    FileUtils.mkdir_p(slot_path.join("nested"))
    File.write(slot_path.join("nested", "actual.txt"), "changed\n")

    result_path = workspace.root_path.join(".a3", "worker-result.json")
    bundle = {
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "implementation",
      "success" => true,
      "summary" => "implemented",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => { "repo_beta" => ["declared.txt"] }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do |_commands, workspace:, env:|
      expect(env["A3_WORKER_RESULT_PATH"]).to eq(result_path.to_s)
      result_path.dirname.mkpath
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(success: true, summary: "command runner succeeded")
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: ticket_run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(true)
    expect(execution.response_bundle.fetch("changed_files")).to eq(
      "repo_beta" => ["nested/actual.txt"]
    )
    expect(execution.diagnostics).to include(
      "worker_changed_files" => { "repo_beta" => ["declared.txt"] },
      "canonical_changed_files" => { "repo_beta" => ["nested/actual.txt"] }
    )
  end

  it "accepts a parent review result without changed_files when review_disposition is present" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    parent_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: workspace.workspace_kind,
      root_path: workspace.root_path,
      source_descriptor: workspace.source_descriptor,
      slot_paths: {
        repo_alpha: Pathname(tmpdir).join("workspace", "repo-alpha"),
        repo_beta: Pathname(tmpdir).join("workspace", "repo-beta")
      }
    )
    FileUtils.mkdir_p(parent_workspace.slot_paths.fetch(:repo_alpha))
    parent_task = A3::Domain::Task.new(
      ref: "Portal#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta]
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-review-1",
      task_ref: parent_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: workspace.source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base-1",
        head_commit: "head-1",
        task_ref: parent_task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "head-1"
      )
    )
    parent_phase_runtime = A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :parent,
      repo_scope: :both,
      phase: :review,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash
    )
    bundle = {
      "task_ref" => parent_task.ref,
      "run_ref" => parent_run.ref,
      "phase" => "review",
      "success" => true,
      "summary" => "parent review clean",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "review_disposition" => {
        "kind" => "completed",
        "repo_scope" => "both",
        "summary" => "No findings",
        "description" => "Parent integration snapshot is clean.",
        "finding_key" => "completed-no-findings"
      }
    }
    gateway = described_class.new(
      command_runner: command_runner,
      worker_protocol: A3::Infra::WorkerProtocol.new(review_disposition_repo_scopes: %w[repo_alpha repo_beta both])
    )

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(success: true, summary: "command runner succeeded")
    end

    execution = gateway.run(
      skill: parent_phase_runtime.review_skill,
      workspace: parent_workspace,
      task: parent_task,
      run: parent_run,
      phase_runtime: parent_phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(true)
    expect(execution.response_bundle).to eq(bundle)
  end

  it "accepts a parent review result with changed_files null when review_disposition is present" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    parent_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: workspace.workspace_kind,
      root_path: workspace.root_path,
      source_descriptor: workspace.source_descriptor,
      slot_paths: {
        repo_alpha: Pathname(tmpdir).join("workspace", "repo-alpha"),
        repo_beta: Pathname(tmpdir).join("workspace", "repo-beta")
      }
    )
    FileUtils.mkdir_p(parent_workspace.slot_paths.fetch(:repo_alpha))
    parent_task = A3::Domain::Task.new(
      ref: "Portal#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta]
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-review-2",
      task_ref: parent_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: workspace.source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base-1",
        head_commit: "head-1",
        task_ref: parent_task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "head-1"
      )
    )
    parent_phase_runtime = A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :parent,
      repo_scope: :both,
      phase: :review,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash
    )
    bundle = {
      "task_ref" => parent_task.ref,
      "run_ref" => parent_run.ref,
      "phase" => "review",
      "success" => true,
      "summary" => "parent review clean",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => nil,
      "review_disposition" => {
        "kind" => "completed",
        "repo_scope" => "both",
        "summary" => "No findings",
        "description" => "Parent integration snapshot is clean.",
        "finding_key" => "completed-no-findings"
      }
    }
    gateway = described_class.new(
      command_runner: command_runner,
      worker_protocol: A3::Infra::WorkerProtocol.new(review_disposition_repo_scopes: %w[repo_alpha repo_beta both])
    )

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(success: true, summary: "command runner succeeded")
    end

    execution = gateway.run(
      skill: parent_phase_runtime.review_skill,
      workspace: parent_workspace,
      task: parent_task,
      run: parent_run,
      phase_runtime: parent_phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(true)
    expect(execution.response_bundle).to eq(bundle)
  end

  it "accepts implementation review evidence alongside changed_files" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    bundle = {
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "implementation",
      "success" => true,
      "summary" => "implementation clean",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => { "repo_beta" => ["nested/actual.txt"] },
      "review_disposition" => {
        "kind" => "completed",
        "repo_scope" => "repo_beta",
        "summary" => "No findings",
        "description" => "Implementation finished and final self-review found no outstanding issues.",
        "finding_key" => "completed-no-findings"
      }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      workspace.slot_paths.fetch(:repo_beta).join("nested").mkpath
      workspace.slot_paths.fetch(:repo_beta).join("nested", "actual.txt").write("changed")
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(success: true, summary: "command runner succeeded")
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(true)
    expect(execution.response_bundle.fetch("review_disposition")).to eq(
      "kind" => "completed",
      "repo_scope" => "repo_beta",
      "summary" => "No findings",
      "description" => "Implementation finished and final self-review found no outstanding issues.",
      "finding_key" => "completed-no-findings"
    )
  end

  it "fails fast when parent review disposition uses a non-canonical kind" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    parent_task = A3::Domain::Task.new(
      ref: "Portal#3140",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta]
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-review-3",
      task_ref: parent_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: workspace.source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: %i[repo_alpha repo_beta],
        verification_scope: %i[repo_alpha repo_beta],
        ownership_scope: :parent
      ),
      review_target: A3::Domain::ReviewTarget.new(
        base_commit: "base-1",
        head_commit: "head-1",
        task_ref: parent_task.ref,
        phase_ref: :review
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "head-1"
      )
    )
    parent_phase_runtime = A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :parent,
      repo_scope: :both,
      phase: :review,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash
    )
    bundle = {
      "task_ref" => parent_task.ref,
      "run_ref" => parent_run.ref,
      "phase" => "review",
      "success" => true,
      "summary" => "parent review clean",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "review_disposition" => {
        "kind" => "banana",
        "repo_scope" => "both",
        "summary" => "No findings",
        "description" => "Parent integration snapshot is clean.",
        "finding_key" => "completed-no-findings"
      }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(success: true, summary: "command runner succeeded")
    end

    execution = gateway.run(
      skill: parent_phase_runtime.review_skill,
      workspace: workspace,
      task: parent_task,
      run: parent_run,
      phase_runtime: parent_phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.diagnostics.fetch("validation_errors")).to include(
      "review_disposition.kind must be one of completed, follow_up_child, blocked"
    )
  end

  it "fails fast when implementation review evidence is not canonical completed evidence" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    bundle = {
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "implementation",
      "success" => true,
      "summary" => "implementation clean",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => { "repo_beta" => ["declared.txt"] },
      "review_disposition" => {
        "kind" => "follow_up_child",
        "repo_scope" => "repo_beta",
        "summary" => "No findings",
        "description" => "Invalid implementation evidence.",
        "finding_key" => "invalid-implementation-evidence"
      }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(bundle))
      A3::Application::ExecutionResult.new(success: true, summary: "command runner succeeded")
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.diagnostics.fetch("validation_errors")).to include(
      "review_disposition.kind must be completed for implementation evidence"
    )
  end

  it "fails fast when worker result identity fields do not match the worker request" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    invalid_bundle = {
      "task_ref" => task.ref,
      "run_ref" => "run-other",
      "phase" => "review",
      "success" => false,
      "summary" => "review blocked",
      "failing_command" => "worker review",
      "observed_state" => "blocked_refresh_failure",
      "rework_required" => false,
      "diagnostics" => { "stderr" => "refresh failed" }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(invalid_bundle))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.failing_command).to eq("worker_result_schema")
    expect(execution.observed_state).to eq("invalid_worker_result")
    expect(execution.diagnostics).to eq(
      "validation_errors" => [
        "run_ref must match the worker request",
        "phase must match the worker request"
      ]
    )
    expect(execution.response_bundle).to eq(invalid_bundle)
  end

  it "fails fast when a worker result bundle is present but violates the expected schema" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    invalid_bundle = {
      "success" => "false",
      "summary" => ["review blocked"],
      "rework_required" => "false",
      "diagnostics" => ["refresh failed"]
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(invalid_bundle))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.failing_command).to eq("worker_result_schema")
    expect(execution.observed_state).to eq("invalid_worker_result")
    expect(execution.diagnostics).to eq(
        "validation_errors" => [
          "success must be true or false",
          "summary must be a string",
          "diagnostics must be an object",
          "rework_required must be true or false"
        ]
      )
    expect(execution.response_bundle).to eq(invalid_bundle)
  end

  it "fails fast when changed_files has an invalid shape" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    invalid_bundle = {
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "implementation",
      "success" => true,
      "summary" => "implemented",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => { "repo_beta" => [1, 2] }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(invalid_bundle))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.diagnostics).to eq(
      "validation_errors" => [
        "changed_files for repo_beta must be an array of strings"
      ]
    )
  end

  it "fails fast when a failed worker result omits a valid observed state" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    invalid_bundle = {
      "success" => false,
      "summary" => "review blocked",
      "failing_command" => ["worker review"],
      "rework_required" => false,
      "diagnostics" => { "stderr" => "refresh failed" }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(invalid_bundle))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.diagnostics).to eq(
      "validation_errors" => [
        "failing_command must be a string when success is false unless rework_required is true",
        "observed_state must be a string when success is false"
      ]
    )
    expect(execution.response_bundle).to eq(invalid_bundle)
  end

  it "fails fast when a failed worker result omits failing_command" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    invalid_bundle = {
      "success" => false,
      "summary" => "review blocked",
      "observed_state" => "blocked_refresh_failure",
      "rework_required" => false,
      "diagnostics" => { "stderr" => "refresh failed" }
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(invalid_bundle))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.failing_command).to eq("worker_result_schema")
    expect(execution.observed_state).to eq("invalid_worker_result")
    expect(execution.diagnostics).to eq(
      "validation_errors" => [
        "failing_command must be a string when success is false unless rework_required is true"
      ]
    )
    expect(execution.response_bundle).to eq(invalid_bundle)
  end

  it "fails fast when a worker result bundle is valid JSON but not an object" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(["not", "an", "object"]))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.failing_command).to eq("worker_result_schema")
    expect(execution.observed_state).to eq("invalid_worker_result")
    expect(execution.diagnostics).to eq(
      "validation_errors" => ["worker result payload must be an object"]
    )
    expect(execution.response_bundle).to eq(["not", "an", "object"])
  end

  it "fails fast when a worker result bundle is json null" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write("null")
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.failing_command).to eq("worker_result_schema")
    expect(execution.observed_state).to eq("invalid_worker_result")
    expect(execution.diagnostics).to eq(
      "validation_errors" => ["worker result payload must be an object"]
    )
    expect(execution.response_bundle).to eq("raw" => "null")
  end

  it "fails fast when a worker result file is not valid json" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write("{not-json")
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end
    parser_error = JSON::ParserError.new("unexpected token")
    allow(JSON).to receive(:parse).and_wrap_original do |original, payload|
      if payload == "{not-json"
        result_path.delete
        raise parser_error
      end

      original.call(payload)
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result json invalid")
    expect(execution.failing_command).to eq("worker_result_json")
    expect(execution.observed_state).to eq("invalid_worker_result")
    expect(execution.diagnostics.fetch("validation_errors")).to include("worker result file is not valid JSON")
    expect(execution.response_bundle).to eq("raw" => "{not-json")
  end

  it "fails fast when optional worker result fields have invalid types" do
    result_path = workspace.root_path.join(".a3", "worker-result.json")
    invalid_bundle = {
      "success" => false,
      "summary" => "review blocked",
      "failing_command" => ["worker review"],
      "observed_state" => { "state" => "blocked_refresh_failure" },
      "rework_required" => false
    }
    gateway = described_class.new(command_runner: command_runner)

    allow(command_runner).to receive(:run) do
      result_path.write(JSON.pretty_generate(invalid_bundle))
      A3::Application::ExecutionResult.new(
        success: true,
        summary: "command runner succeeded"
      )
    end

    execution = gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution.success?).to be(false)
    expect(execution.summary).to eq("worker result schema invalid")
    expect(execution.diagnostics).to eq(
      "validation_errors" => [
        "failing_command must be a string when success is false unless rework_required is true",
        "observed_state must be a string when present"
      ]
    )
  end
end
