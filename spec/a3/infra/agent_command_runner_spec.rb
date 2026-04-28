# frozen_string_literal: true

require "digest"
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
  let(:source_descriptor) { A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Sample#42", ref: "refs/heads/a2o/work/Sample-42") }
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-workspace",
      source_descriptor: source_descriptor,
      slot_paths: {}
    )
  end
  let(:task) { A3::Domain::Task.new(ref: "Sample#42", project_key: "a2o", kind: :single, edit_scope: [:repo_alpha], status: :verifying) }
  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      project_key: "a2o",
      task_ref: task.ref,
      phase: :verification,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(edit_scope: [:repo_alpha], verification_scope: [:repo_alpha], ownership_scope: :task),
      artifact_owner: A3::Domain::ArtifactOwner.new(owner_ref: task.ref, owner_scope: :task, snapshot_version: "refs/heads/a2o/work/Sample-42")
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
    expect(request.project_key).to eq("a2o")
    expect(request.runtime_profile).to eq("docker-dev-env")
    expect(request.env).to include(
      "AUTOMATION_ISSUE_WORKSPACE" => "/tmp/a3-workspace",
      "MAVEN_REPO_LOCAL" => "/tmp/a3-workspace/.work/m2/repository"
    )
    expect(result).to have_attributes(success?: true, summary: "task test:all ok")
    expect(result.diagnostics.fetch("agent_artifacts").fetch(0)).to include(
      "artifact_id" => "command-run-1-verification-job-1-combined-log",
      "role" => "combined-log"
    )
  end

  it "does not emit runtime-side command job lifecycle diagnostics by default" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    expect do
      runner.run(["task test:all"], workspace: workspace, task: task, run: run, command_intent: :verification)
    end.not_to output(a_string_including("runtime_agent_command_event")).to_stderr
  end

  it "emits runtime-side command job lifecycle diagnostics when trace is enabled" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    with_env("A2O_RUNTIME_AGENT_JOB_TRACE" => "1") do
      expect do
        runner.run(["task test:all"], workspace: workspace, task: task, run: run, command_intent: :verification)
      end.to output(
        a_string_including(
          "runtime_agent_command_event",
          "\"stage\":\"enqueue_start\"",
          "\"stage\":\"wait_done\"",
          "\"job_id\":\"command-run-1-verification-job-1\"",
          "\"command_intent\":\"verification\"",
          "\"result_status\":\"succeeded\""
        )
      ).to_stderr
    end
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
    builder = A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {repo_alpha: "sample-catalog-service"})
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
      "source" => {"kind" => "local_git", "alias" => "sample-catalog-service"},
      "access" => "read_only"
    )
    expect(runner.agent_owned_workspace?).to eq(true)
  end

  it "passes metrics collection intent to materialized command jobs as read-only work" do
    client.on_fetch = ->(job_id) do
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: {
            "success" => true,
            "summary" => "metrics collected",
            "diagnostics" => {
              "stdout" => "{\"tests\":{\"passed_count\":3}}\n",
              "stderr" => ""
            }
          }
        )
      )
    end
    builder = A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {repo_alpha: "sample-catalog-service"})
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "agent-materialized",
      workspace_request_builder: builder,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["task metrics"], workspace: workspace, task: task, run: run, command_intent: :metrics_collection)

    request = client.records.values.first.request
    expect(result).to have_attributes(success?: true, summary: "task metrics ok")
    expect(result.diagnostics).to include(
      "stdout" => "{\"tests\":{\"passed_count\":3}}\n",
      "stderr" => ""
    )
    expect(request.worker_protocol_request).to eq("command_intent" => "metrics_collection")
    expect(request.workspace_request.publish_policy).to be_nil
    expect(request.workspace_request.slots.fetch("repo_alpha")).to include("access" => "read_only")
  end

  it "passes notification command output through diagnostics without a worker protocol request" do
    client.on_fetch = ->(job_id) do
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: {
            "success" => true,
            "summary" => "notification sent",
            "diagnostics" => {
              "stdout" => "notified\n",
              "stderr" => "warning\n"
            }
          }
        )
      )
    end
    builder = A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {repo_alpha: "sample-catalog-service"})
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "agent-materialized",
      workspace_request_builder: builder,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["notify"], workspace: workspace, task: task, run: run, command_intent: :notification)

    request = client.records.values.first.request
    expect(result).to have_attributes(success?: true, summary: "notify ok")
    expect(result.diagnostics).to include(
      "stdout" => "notified\n",
      "stderr" => "warning\n"
    )
    expect(request.worker_protocol_request).to be_nil
    expect(request.workspace_request.publish_policy).to be_nil
    expect(request.workspace_request.slots.fetch("repo_alpha")).to include("access" => "read_only")
  end

  it "passes failed notification command output through diagnostics" do
    client.on_fetch = ->(job_id) do
      client.complete(
        job_id,
        agent_result(
          job_id,
          :failed,
          9,
          worker_protocol_result: {
            "success" => false,
            "summary" => "notification failed",
            "diagnostics" => {
              "stdout" => "before failure\n",
              "stderr" => "notify failed\n"
            }
          }
        )
      )
    end
    builder = A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {repo_alpha: "sample-catalog-service"})
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "agent-materialized",
      workspace_request_builder: builder,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["notify"], workspace: workspace, task: task, run: run, command_intent: :notification)

    expect(result).to have_attributes(success?: false, summary: "notify failed")
    expect(result.diagnostics).to include(
      "stdout" => "before failure\n",
      "stderr" => "notify failed\n"
    )
    expect(result.diagnostics.fetch("agent_job_result")).to include("status" => "failed", "exit_code" => 9)
  end

  it "concatenates metrics stdout and stderr across successful agent commands" do
    call_count = 0
    client.on_fetch = lambda do |job_id|
      call_count += 1
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: {
            "success" => true,
            "summary" => "metrics part #{call_count}",
            "diagnostics" => {
              "stdout" => call_count == 1 ? "{\"tests\":" : "{\"passed_count\":3}}\n",
              "stderr" => call_count == 1 ? "first warning\n" : "second warning\n"
            }
          }
        )
      )
    end
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["task metrics:begin", "task metrics:end"], workspace: workspace, task: task, run: run, command_intent: :metrics_collection)

    expect(result).to have_attributes(success?: true, summary: "task metrics:begin ok; task metrics:end ok")
    expect(result.diagnostics).to include(
      "stdout" => "{\"tests\":{\"passed_count\":3}}\n",
      "stderr" => "first warning\nsecond warning\n"
    )
  end

  it "passes public worker protocol requests to materialized command jobs" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    builder = A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {repo_alpha: "sample-catalog-service"})
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "agent-materialized",
      workspace_request_builder: builder,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )
    worker_protocol_request = {
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "verification",
      "command_intent" => "verification",
      "slot_paths" => {"repo_alpha" => "/tmp/a3-workspace/repo-alpha"}
    }

    result = runner.run(["task verify"], workspace: workspace, task: task, run: run, worker_protocol_request: worker_protocol_request)

    request = client.records.values.first.request
    expect(result.success?).to eq(true)
    expect(request.worker_protocol_request).to eq(worker_protocol_request)
    expect(request.env).to include(
      "AUTOMATION_ISSUE_WORKSPACE" => "/tmp/a3-workspace",
      "MAVEN_REPO_LOCAL" => "/tmp/a3-workspace/.work/m2/repository"
    )
  end

  it "marks remediation command jobs as publishable edit-target mutations" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    builder = A3::Infra::AgentWorkspaceRequestBuilder.new(source_aliases: {repo_alpha: "sample-catalog-service"})
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "agent-materialized",
      workspace_request_builder: builder,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["ruby sample_remediation.rb"], workspace: workspace, task: task, run: run, command_intent: :remediation)

    request = client.records.values.first.request
    expect(result.success?).to eq(true)
    expect(request.workspace_request.publish_policy).to eq(
      "mode" => "commit_all_edit_target_changes_on_success",
      "commit_message" => "A2O remediation update for Sample#42"
    )
    expect(request.workspace_request.slots.fetch("repo_alpha")).to include("access" => "read_write")
  end

  it "passes explicit agent env overrides to command jobs" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      env: { A2O_ROOT_DIR: "/host/a2o" },
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(["task verify"], workspace: workspace, task: task, run: run)

    request = client.records.values.first.request
    expect(result.success?).to eq(true)
    expect(request.env.fetch("A2O_ROOT_DIR")).to eq("/host/a2o")
  end

  it "rejects legacy A3_ROOT_DIR when A2O_ROOT_DIR is absent" do
    original_public = ENV.delete("A2O_ROOT_DIR")
    original_legacy = ENV["A3_ROOT_DIR"]
    ENV["A3_ROOT_DIR"] = "/tmp/legacy-root"
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    expect do
      runner.run(["task verify"], workspace: workspace, task: task, run: run)
    end.to raise_error(
      KeyError,
      /removed A3 root utility input: environment variable A3_ROOT_DIR; migration_required=true replacement=environment variable A2O_ROOT_DIR/
    )
  ensure
    original_public ? ENV["A2O_ROOT_DIR"] = original_public : ENV.delete("A2O_ROOT_DIR")
    original_legacy ? ENV["A3_ROOT_DIR"] = original_legacy : ENV.delete("A3_ROOT_DIR")
  end

  it "rejects explicit legacy A3_ROOT_DIR during runner construction" do
    expect do
      described_class.new(
        control_plane_client: client,
        runtime_profile: "docker-dev-env",
        shared_workspace_mode: "same-path",
        env: { "A3_ROOT_DIR" => "/tmp/legacy-root" },
        job_id_generator: -> { "job-1" },
        sleeper: ->(_) {}
      )
    end.to raise_error(
      KeyError,
      /removed A3 root utility input: environment variable A3_ROOT_DIR; migration_required=true replacement=environment variable A2O_ROOT_DIR/
    )
  end

  it "expands public command placeholders before enqueueing agent jobs" do
    client.on_fetch = ->(job_id) { client.complete(job_id, agent_result(job_id, :succeeded, 0)) }
    runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "docker-dev-env",
      shared_workspace_mode: "same-path",
      job_id_generator: -> { "job-1" },
      sleeper: ->(_) {}
    )

    result = runner.run(
      ["ruby {{a2o_root_dir}}/commands/verify.rb --workspace {{workspace_root}}"],
      workspace: workspace,
      task: task,
      run: run,
      env: { "A2O_ROOT_DIR" => "/host/a2o-root" }
    )

    request = client.records.values.first.request
    expect(result).to have_attributes(
      success?: true,
      summary: "ruby /host/a2o-root/commands/verify.rb --workspace /tmp/a3-workspace ok"
    )
    expect(request.args).to eq(["-lc", "ruby /host/a2o-root/commands/verify.rb --workspace /tmp/a3-workspace"])
    expect(request.env.fetch("A2O_ROOT_DIR")).to eq("/host/a2o-root")
  end

  def agent_result(job_id, status, exit_code, worker_protocol_result: nil)
    A3::Domain::AgentJobResult.new(
      job_id: job_id,
      project_key: "a2o",
      status: status,
      exit_code: exit_code,
      started_at: "2026-04-11T08:00:00Z",
      finished_at: "2026-04-11T08:00:01Z",
      summary: "agent #{status}",
      log_uploads: [
        A3::Domain::AgentArtifactUpload.new(
          artifact_id: "#{job_id}-combined-log",
          project_key: "a2o",
          role: "combined-log",
          digest: "sha256:#{Digest::SHA256.hexdigest('agent log')}",
          byte_size: "agent log".bytesize,
          retention_class: :diagnostic,
          media_type: "text/plain"
        )
      ],
      artifact_uploads: [],
      workspace_descriptor: A3::Domain::AgentWorkspaceDescriptor.new(
        workspace_kind: :runtime_workspace,
        project_key: "a2o",
        runtime_profile: "docker-dev-env",
        workspace_id: "workspace-1",
        source_descriptor: source_descriptor,
        slot_descriptors: {}
      ),
      worker_protocol_result: worker_protocol_result,
      heartbeat: "2026-04-11T08:00:01Z"
    )
  end

  def with_env(values)
    previous = values.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
