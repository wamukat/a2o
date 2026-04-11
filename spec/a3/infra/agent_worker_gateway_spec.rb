# frozen_string_literal: true

require "json"
require "spec_helper"
require "tmpdir"

RSpec.describe A3::Infra::AgentWorkerGateway do
  FakeClient = Struct.new(:records, :on_fetch, :base_url, keyword_init: true) do
    def enqueue(request)
      record = A3::Domain::AgentJobRecord.new(request: request, state: :queued)
      records[request.job_id] = record
      record
    end

    def fetch(job_id)
      on_fetch&.call(job_id)
      records.fetch(job_id)
    end

    def complete(job_id, result)
      records[job_id] = records.fetch(job_id).complete(result)
    end
  end

  let(:tmpdir) { Dir.mktmpdir("a3-agent-worker-gateway") }
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: Pathname(tmpdir).join("workspace"),
      source_descriptor: source_descriptor,
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
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :child
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
      title: "Implement agent gateway",
      description: "Bridge worker protocol through agent jobs.",
      status: "In progress",
      labels: []
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
  let(:client) { FakeClient.new(records: {}, base_url: "http://127.0.0.1:4567") }

  before do
    FileUtils.mkdir_p(workspace.root_path)
    FileUtils.mkdir_p(workspace.slot_paths.fetch(:repo_beta))
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it "returns the worker result after an agent job completes" do
    client.on_fetch = lambda do |job_id|
      workspace.root_path.join(".a3", "worker-result.json").write(JSON.generate(worker_success))
      client.complete(job_id, agent_result(job_id, :succeeded, 0))
    end
    gateway = gateway_for(client)

    execution = run_gateway(gateway)

    request = client.records.values.first.request
    expect(request.command).to eq("ruby")
    expect(request.args).to eq(["worker.rb"])
    expect(request.env).to include(
      "A3_WORKER_REQUEST_PATH" => workspace.root_path.join(".a3", "worker-request.json").to_s
    )
    expect(execution).to have_attributes(
      success: true,
      summary: "worker completed"
    )
    expect(execution.response_bundle.fetch("changed_files")).to eq({})
  end

  it "requires a worker result when an agent job succeeds" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    gateway = gateway_for(client)

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: false,
      failing_command: "worker_result_schema",
      observed_state: "invalid_worker_result"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("worker result file is missing")
  end

  it "returns the agent result when the agent job fails without a worker result" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :failed, 127)) }
    gateway = gateway_for(client)

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: false,
      summary: "agent failed",
      failing_command: "agent_job",
      observed_state: "failed"
    )
    expect(execution.diagnostics.fetch("agent_job_result")).to include(
      "status" => "failed",
      "exit_code" => 127
    )
  end

  it "fails before enqueue unless same-path shared workspace mode is explicit" do
    gateway = described_class.new(
      control_plane_client: client,
      worker_command: "ruby",
      worker_command_args: ["worker.rb"],
      runtime_profile: "host-local",
      shared_workspace_mode: "mapped-path"
    )

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: false,
      observed_state: "agent_workspace_unavailable"
    )
    expect(client.records).to be_empty
  end

  def gateway_for(client)
    described_class.new(
      control_plane_client: client,
      worker_command: "ruby",
      worker_command_args: ["worker.rb"],
      runtime_profile: "host-local",
      shared_workspace_mode: "same-path",
      timeout_seconds: 30,
      poll_interval_seconds: 0,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_seconds) {}
    )
  end

  def run_gateway(gateway)
    gateway.run(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )
  end

  def worker_success
    {
      "success" => true,
      "summary" => "worker completed",
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "implementation",
      "rework_required" => false,
      "changed_files" => {},
      "review_disposition" => {
        "kind" => "completed",
        "repo_scope" => "repo_beta",
        "summary" => "done",
        "description" => "done",
        "finding_key" => "none"
      }
    }
  end

  def agent_result(job_id, status, exit_code)
    A3::Domain::AgentJobResult.new(
      job_id: job_id,
      status: status,
      exit_code: exit_code,
      started_at: "2026-04-11T08:00:00Z",
      finished_at: "2026-04-11T08:00:01Z",
      summary: status == :succeeded ? "agent succeeded" : "agent failed",
      log_uploads: [],
      artifact_uploads: [],
      workspace_descriptor: workspace_descriptor,
      heartbeat: "2026-04-11T08:00:01Z"
    )
  end

  def source_descriptor
    A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: task.ref, ref: "abc123")
  end

  def workspace_descriptor
    A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      runtime_profile: "host-local",
      workspace_id: "host-local-job-1",
      source_descriptor: source_descriptor,
      slot_descriptors: {}
    )
  end
end
