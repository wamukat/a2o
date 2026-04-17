# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Infra::AgentCommandRunner do
  FakeAgentCommandClient = Struct.new(:records, :on_fetch, :base_url, keyword_init: true) do
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

  let(:client) { FakeAgentCommandClient.new(records: {}, base_url: "http://127.0.0.1:7393") }
  let(:source_descriptor) { A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Portal#42", ref: "refs/heads/a3/work/Portal-42") }
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-workspace",
      source_descriptor: source_descriptor,
      slot_paths: {}
    )
  end
  let(:task) { A3::Domain::Task.new(ref: "Portal#42", kind: :single, edit_scope: [:repo_alpha], status: :verifying) }
  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      task_ref: task.ref,
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
      artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: task.ref, owner_scope: :task, snapshot_version: "refs/heads/a3/work/Portal-42")
    )
  end

  it "runs verification commands through agent jobs" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["task test:all"], workspace: workspace, task: task, run: run)

    request = client.records.values.first.request
    expect(request.command).to eq("sh")
    expect(request.args).to eq(["-lc", "task test:all"])
    expect(request.phase).to eq(:verification)
    expect(request.runtime_profile).to eq("docker-dev-env")
    expect(result).to have_attributes(success?: true, summary: "task test:all ok")
  end

  it "returns agent result diagnostics when a verification command fails" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :failed, 1)) }
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["task test:nullaway"], workspace: workspace, task: task, run: run)

    expect(result).to have_attributes(
      success?: false,
      summary: "task test:nullaway failed",
      failing_command: "task test:nullaway",
      observed_state: "failed"
    )
    expect(result.diagnostics.fetch("agent_job_result")).to include("status" => "failed", "exit_code" => 1)
  end

  it "passes materialized workspace requests to the agent" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    builder = A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {repo_alpha: "member-portal-starters"})
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "agent-materialized",
      workspace_request_builder: builder,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["task verify"], workspace: workspace, task: task, run: run)

    request = client.records.values.first.request
    expect(result.success?).to eq(true)
    expect(request.workspace_request.request_form).to include(
      "mode" => "agent_materialized",
      "workspace_kind" => "runtime_workspace"
    )
    expect(request.workspace_request.slots.fetch("repo_alpha")).to include(
      "source" => {"kind" => "local_git", "alias" => "member-portal-starters"},
      "access" => "read_only"
    )
    expect(runner.agent_owned_workspace?).to eq(true)
  end

  it "marks remediation command jobs as publishable edit-target mutations" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    builder = A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {repo_alpha: "member-portal-starters"})
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "agent-materialized",
      workspace_request_builder: builder,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["ruby portal_remediation.rb"], workspace: workspace, task: task, run: run, command_intent: :remediation)

    request = client.records.values.first.request
    expect(result.success?).to eq(true)
    expect(request.workspace_request.publish_policy).to eq(
      "mode" => "commit_all_edit_target_changes_on_success",
      "commit_message" => "A3 remediation update for Portal#42"
    )
    expect(request.workspace_request.slots.fetch("repo_alpha")).to include("access" => "read_write")
  end

  it "passes explicit agent env overrides to command jobs" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      env: { A3_ROOT_DIR: "/host/a3" },
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["task verify"], workspace: workspace, task: task, run: run)

    request = client.records.values.first.request
    expect(result.success?).to eq(true)
    expect(request.env.fetch("A3_ROOT_DIR")).to eq("/host/a3")
  end

  def agent_result(job_id, status, exit_code)
    A3::Domain::AgentJobResult.new(
      job_id: job_id,
      status: status,
      exit_code: exit_code,
      started_at: "2026-04-11T08:00:00Z",
      finished_at: "2026-04-11T08:00:01Z",
      summary: "agent #{status}",
      log_uploads: [],
      artifact_uploads: [],
      workspace_descriptor: A3::Domain::AgentWorkspaceDescriptor.new(
        workspace_kind: :runtime_workspace,
        runtime_profile: "docker-dev-env",
        workspace_id: "workspace-1",
        source_descriptor: source_descriptor,
        slot_descriptors: {}
      ),
      heartbeat: "2026-04-11T08:00:01Z"
    )
  end
end
