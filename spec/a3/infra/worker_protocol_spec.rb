# frozen_string_literal: true

require "json"
require "spec_helper"
require "tmpdir"

RSpec.describe A3::Infra::WorkerProtocol do
  let(:tmpdir) { Dir.mktmpdir("a3-worker-protocol") }
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
      phase: :review,
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
      title: "Review worker protocol",
      description: "Review agent materialized worker protocol.",
      status: "In progress",
      labels: []
    )
  end
  let(:phase_runtime) do
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :ui_app,
      phase: :review,
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
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it "exposes the same request payload that write_request persists" do
    protocol = described_class.new
    request_form = protocol.request_form(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    protocol.write_request(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    persisted = JSON.parse(workspace.root_path.join(".a3", "worker-request.json").read)
    expect(persisted).to eq(request_form)
    expect(request_form).to include(
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "review",
      "skill" => "task review"
    )
  end

  def source_descriptor
    A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: task.ref, ref: "abc123")
  end
end
