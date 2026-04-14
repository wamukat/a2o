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

  it "requires a workspace request builder for agent materialized mode" do
    gateway = described_class.new(
      control_plane_client: client,
      worker_command: "ruby",
      worker_command_args: ["worker.rb"],
      runtime_profile: "host-local",
      shared_workspace_mode: "agent-materialized"
    )

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: false,
      failing_command: "agent_worker_gateway_config",
      observed_state: "agent_worker_gateway_invalid_config"
    )
    expect(client.records).to be_empty
  end

  it "enqueues worker protocol payload without writing local worker files in agent materialized mode" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: {
            "success" => true,
            "summary" => "review completed",
            "task_ref" => task.ref,
            "run_ref" => review_run.ref,
            "phase" => "review",
            "rework_required" => false
          },
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_slot_descriptor_without_changed_files
          )
        )
      )
    end
    gateway = materialized_gateway

    execution = gateway.run(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: review_run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    request = client.records.values.first.request
    expect(request.workspace_request).to eq(materialized_workspace_request(publish: false))
    expect(request.worker_protocol_request).to include(
      "task_ref" => task.ref,
      "run_ref" => review_run.ref,
      "phase" => "review",
      "skill" => phase_runtime.review_skill
    )
    expect(workspace.root_path.join(".a3", "worker-request.json")).not_to exist
    expect(execution).to have_attributes(
      success: true,
      summary: "review completed"
    )
  end

  it "rejects materialized review when workspace descriptor metadata does not match the request" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: {
            "success" => true,
            "summary" => "review completed",
            "task_ref" => task.ref,
            "run_ref" => review_run.ref,
            "phase" => "review",
            "rework_required" => false
          },
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_slot_descriptor_without_changed_files.merge(
              "branch_ref" => "refs/heads/a3/work/wrong"
            )
          )
        )
      )
    end
    gateway = materialized_gateway

    execution = gateway.run(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: review_run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution).to have_attributes(
      success: false,
      failing_command: "agent_materialized_changed_files",
      observed_state: "agent_materialized_changed_files_invalid"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("repo_beta.branch_ref must match workspace_request")
  end

  it "rejects materialized verification when workspace descriptor metadata does not match the request" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: {
            "success" => true,
            "summary" => "verification completed",
            "task_ref" => task.ref,
            "run_ref" => verification_run.ref,
            "phase" => "verification",
            "rework_required" => false
          },
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_slot_descriptor_without_changed_files.merge(
              "ownership" => "support"
            )
          )
        )
      )
    end
    gateway = materialized_gateway

    execution = gateway.run(
      skill: "verification",
      workspace: workspace,
      task: task,
      run: verification_run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(execution).to have_attributes(
      success: false,
      failing_command: "agent_materialized_changed_files",
      observed_state: "agent_materialized_changed_files_invalid"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("repo_beta.ownership must match workspace_request")
  end

  it "accepts successful implementation in agent materialized mode using descriptor changed files as canonical evidence" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: worker_success.merge("changed_files" => { "repo_beta" => ["worker-claimed.txt"] }),
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_published_slot_descriptor("changed.txt")
          )
        )
      )
    end
    gateway = materialized_gateway

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: true,
      summary: "worker completed"
    )
    expect(execution.response_bundle.fetch("changed_files")).to eq("repo_beta" => ["changed.txt"])
    expect(execution.diagnostics.fetch("worker_changed_files")).to eq("repo_beta" => ["worker-claimed.txt"])
    expect(execution.diagnostics.fetch("canonical_changed_files")).to eq("repo_beta" => ["changed.txt"])
  end

  it "keeps empty materialized changed_files evidence for no-op implementation slots" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: worker_success.merge("changed_files" => { "repo_beta" => [] }),
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_no_change_slot_descriptor
          )
        )
      )
    end
    gateway = materialized_gateway

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: true,
      summary: "worker completed"
    )
    expect(execution.response_bundle.fetch("changed_files")).to eq("repo_beta" => [])
  end

  it "rejects materialized implementation when publish head does not match resolved head" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: worker_success.merge("changed_files" => { "repo_beta" => ["changed.txt"] }),
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_published_slot_descriptor("changed.txt").merge("resolved_head" => "wrong-head")
          )
        )
      )
    end
    gateway = materialized_gateway

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: false,
      failing_command: "agent_materialized_publish_evidence",
      observed_state: "agent_materialized_publish_evidence_invalid"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("repo_beta.publish_after_head must match resolved_head")
  end

  it "requires skipped publish evidence for support slots in publish policy requests" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: worker_success.merge("changed_files" => { "repo_beta" => ["changed.txt"] }),
          workspace_descriptor: workspace_descriptor(
            "repo_alpha" => materialized_support_slot_descriptor,
            "repo_beta" => materialized_published_slot_descriptor("changed.txt")
          )
        )
      )
    end
    gateway = described_class.new(
      control_plane_client: client,
      worker_command: "ruby",
      worker_command_args: ["worker.rb"],
      runtime_profile: "host-local",
      shared_workspace_mode: "agent-materialized",
      timeout_seconds: 30,
      poll_interval_seconds: 0,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_seconds) {},
      workspace_request_builder: ->(**) { materialized_workspace_request_with_support_slot }
    )

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: false,
      failing_command: "agent_materialized_publish_evidence",
      observed_state: "agent_materialized_publish_evidence_invalid"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("repo_alpha.publish_status must be skipped for non-edit slots")
  end

  it "does not apply materialized implementation patches to the local publication workspace when agent publish evidence exists" do
    initialize_git_repo(workspace.slot_paths.fetch(:repo_beta))
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: worker_success.merge("changed_files" => { "repo_beta" => ["marker.txt"] }),
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_published_slot_descriptor("marker.txt").merge(
              "patch" => <<~PATCH
                diff --git a/marker.txt b/marker.txt
                new file mode 100644
                index 0000000..ce01362
                --- /dev/null
                +++ b/marker.txt
                @@ -0,0 +1 @@
                +hello
              PATCH
            )
          )
        )
      )
    end
    gateway = materialized_gateway

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(success: true)
    expect(workspace.slot_paths.fetch(:repo_beta).join("marker.txt")).not_to exist
  end

  it "fails closed instead of applying patches when agent publish policy is missing" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: worker_success.merge("changed_files" => { "repo_beta" => ["marker.txt"] }),
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_slot_descriptor("marker.txt").merge(
              "patch" => "diff --git a/marker.txt b/marker.txt\n"
            )
          )
        )
      )
    end
    gateway = described_class.new(
      control_plane_client: client,
      worker_command: "ruby",
      worker_command_args: ["worker.rb"],
      runtime_profile: "host-local",
      shared_workspace_mode: "agent-materialized",
      timeout_seconds: 30,
      poll_interval_seconds: 0,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_seconds) {},
      workspace_request_builder: ->(**) { materialized_workspace_request(publish: false) }
    )

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: false,
      failing_command: "agent_materialized_publish_policy",
      observed_state: "agent_materialized_publish_policy_missing"
    )
  end

  it "passes explicit agent env overrides to worker jobs" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: worker_success.merge("changed_files" => { "repo_beta" => [] }),
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_no_change_slot_descriptor
          )
        )
      )
    end
    gateway = described_class.new(
      control_plane_client: client,
      worker_command: "ruby",
      worker_command_args: ["worker.rb"],
      runtime_profile: "host-local",
      shared_workspace_mode: "agent-materialized",
      timeout_seconds: 30,
      poll_interval_seconds: 0,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_seconds) {},
      workspace_request_builder: ->(**) { materialized_workspace_request },
      env: { A3_ROOT_DIR: "/host/a3" }
    )

    run_gateway(gateway)

    request = client.records.values.first.request
    expect(request.env).to include("A3_ROOT_DIR" => "/host/a3")
    expect(request.env).to include("A3_WORKER_REQUEST_PATH")
  end

  it "rejects materialized implementation when required changed files evidence is missing" do
    client.on_fetch = lambda do |job_id|
      client.complete(
        job_id,
        agent_result(
          job_id,
          :succeeded,
          0,
          worker_protocol_result: worker_success,
          workspace_descriptor: workspace_descriptor(
            "repo_beta" => materialized_slot_descriptor_without_changed_files
          )
        )
      )
    end
    gateway = materialized_gateway

    execution = run_gateway(gateway)

    expect(execution).to have_attributes(
      success: false,
      failing_command: "agent_materialized_changed_files",
      observed_state: "agent_materialized_changed_files_invalid"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("repo_beta.changed_files must be an array of strings")
  end

  it "runs through an HTTP agent server and the Ruby reference agent" do
    job_store = A3::Infra::JsonAgentJobStore.new(File.join(tmpdir, "agent-jobs.json"))
    artifact_store = A3::Infra::FileAgentArtifactStore.new(File.join(tmpdir, "agent-artifacts"))
    handler = A3::Infra::AgentHttpPullHandler.new(
      job_store: job_store,
      artifact_store: artifact_store,
      clock: -> { "2026-04-11T08:00:00Z" }
    )
    server = A3::Infra::AgentHttpPullServer.new(handler: handler, port: 0)
    server_thread = Thread.new { server.start }
    worker_script = write_worker_script

    gateway = described_class.new(
      control_plane_client: A3::Infra::AgentControlPlaneClient.new(base_url: "http://127.0.0.1:#{server.bound_port}"),
      worker_command: RbConfig.ruby,
      worker_command_args: [worker_script.to_s],
      runtime_profile: "host-local",
      shared_workspace_mode: "same-path",
      timeout_seconds: 10,
      poll_interval_seconds: 0.05,
      job_id_generator: -> { "integration-1" }
    )
    gateway_thread = Thread.new { run_gateway(gateway) }

    wait_until { job_store.all.any? }
    agent_client = A3::Agent::HttpControlPlaneClient.new(base_url: "http://127.0.0.1:#{server.bound_port}")
    agent_result = A3::Agent::RunOnceWorker.new(
      agent_name: "host-local",
      control_plane_client: agent_client
    ).call
    execution = gateway_thread.value

    expect(agent_result).to be_a(A3::Domain::AgentJobResult)
    expect(execution).to have_attributes(
      success: true,
      summary: "worker completed via http"
    )
    completed = job_store.fetch("worker-run-1-implementation-integration-1")
    expect(completed).to have_attributes(state: :completed)
    upload = completed.result.log_uploads.find { |entry| entry.role == "combined-log" }
    expect(upload).not_to be_nil
    expect(artifact_store.read(upload.artifact_id)).to include("worker script ran")
  ensure
    server&.shutdown
    server_thread&.join(2)
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

  def materialized_gateway
    described_class.new(
      control_plane_client: client,
      worker_command: "ruby",
      worker_command_args: ["worker.rb"],
      runtime_profile: "host-local",
      shared_workspace_mode: "agent-materialized",
      timeout_seconds: 30,
      poll_interval_seconds: 0,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_seconds) {},
      workspace_request_builder: ->(**kwargs) { materialized_workspace_request(publish: kwargs.fetch(:run).phase.to_sym == :implementation) }
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

  def review_run
    A3::Domain::Run.new(
      ref: "run-review-1",
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

  def verification_run
    A3::Domain::Run.new(
      ref: "run-verification-1",
      task_ref: task.ref,
      phase: :verification,
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

  def materialized_workspace_request(publish: true)
    A3::Domain::AgentWorkspaceRequest.new(
      mode: :agent_materialized,
      workspace_kind: :runtime_workspace,
      workspace_id: "Portal-42-runtime",
      freshness_policy: :reuse_if_clean_and_ref_matches,
      cleanup_policy: :retain_until_a3_cleanup,
      publish_policy: publish ? {
        mode: "commit_all_edit_target_changes_on_worker_success",
        commit_message: "A3 implementation update for #{task.ref}"
      } : nil,
      slots: {
        repo_beta: {
          source: {
            kind: "local_git",
            alias: "member-portal-starters"
          },
          ref: "refs/heads/a3/work/Portal-42",
          checkout: "worktree_branch",
          access: "read_write",
          sync_class: "eager",
          ownership: "edit_target",
          required: true
        }
      }
    )
  end

  def materialized_workspace_request_with_support_slot
    A3::Domain::AgentWorkspaceRequest.new(
      mode: :agent_materialized,
      workspace_kind: :runtime_workspace,
      workspace_id: "Portal-42-runtime",
      freshness_policy: :reuse_if_clean_and_ref_matches,
      cleanup_policy: :retain_until_a3_cleanup,
      publish_policy: {
        mode: "commit_all_edit_target_changes_on_worker_success",
        commit_message: "A3 implementation update for #{task.ref}"
      },
      slots: {
        repo_alpha: {
          source: {
            kind: "local_git",
            alias: "member-portal-ui-app"
          },
          ref: "refs/heads/a3/work/Portal-42",
          checkout: "worktree_branch",
          access: "read_only",
          sync_class: "lazy_but_guaranteed",
          ownership: "support",
          required: true
        },
        repo_beta: {
          source: {
            kind: "local_git",
            alias: "member-portal-starters"
          },
          ref: "refs/heads/a3/work/Portal-42",
          checkout: "worktree_branch",
          access: "read_write",
          sync_class: "eager",
          ownership: "edit_target",
          required: true
        }
      }
    )
  end

  def write_worker_script
    script_path = workspace.root_path.join("worker.rb")
    script_path.write(<<~RUBY)
      require "json"
      puts "worker script ran"
      request = JSON.parse(File.read(ENV.fetch("A3_WORKER_REQUEST_PATH")))
      File.write(
        ENV.fetch("A3_WORKER_RESULT_PATH"),
        JSON.generate(
          "success" => true,
          "summary" => "worker completed via http",
          "task_ref" => request.fetch("task_ref"),
          "run_ref" => request.fetch("run_ref"),
          "phase" => request.fetch("phase"),
          "rework_required" => false,
          "changed_files" => {},
          "review_disposition" => {
            "kind" => "completed",
            "repo_scope" => "repo_beta",
            "summary" => "done",
            "description" => "done",
            "finding_key" => "none"
          }
        )
      )
    RUBY
    script_path
  end

  def wait_until(timeout_seconds: 5)
    deadline = Time.now + timeout_seconds
    until yield
      raise "condition was not met within #{timeout_seconds}s" if Time.now >= deadline

      sleep 0.02
    end
  end

  def initialize_git_repo(path)
    system("git", "-C", path.to_s, "init", "-q")
    system("git", "-C", path.to_s, "config", "user.name", "A3 Test")
    system("git", "-C", path.to_s, "config", "user.email", "a3-test@example.invalid")
    path.join("README.md").write("baseline\n")
    system("git", "-C", path.to_s, "add", "README.md")
    system("git", "-C", path.to_s, "commit", "-q", "-m", "baseline")
  end

  def agent_result(job_id, status, exit_code, worker_protocol_result: nil, workspace_descriptor: self.workspace_descriptor)
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
      worker_protocol_result: worker_protocol_result,
      heartbeat: "2026-04-11T08:00:01Z"
    )
  end

  def source_descriptor
    A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: task.ref, ref: "refs/heads/a3/work/Portal-42")
  end

  def workspace_descriptor(slot_descriptors = {})
    A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      runtime_profile: "host-local",
      workspace_id: "host-local-job-1",
      source_descriptor: source_descriptor,
      slot_descriptors: slot_descriptors
    )
  end

  def materialized_slot_descriptor(*changed_files)
    materialized_slot_descriptor_without_changed_files.merge(
      "changed_files" => changed_files
    )
  end

  def materialized_published_slot_descriptor(*changed_files)
    materialized_slot_descriptor(*changed_files).merge(
      "resolved_head" => "def456",
      "publish_status" => "committed",
      "published" => true,
      "publish_before_head" => "abc123",
      "publish_after_head" => "def456",
      "published_changed_files" => changed_files
    )
  end

  def materialized_no_change_slot_descriptor
    materialized_slot_descriptor.merge(
      "publish_status" => "no_changes",
      "published" => false,
      "published_changed_files" => []
    )
  end

  def materialized_support_slot_descriptor
    materialized_slot_descriptor.merge(
      "source_alias" => "member-portal-ui-app",
      "access" => "read_only",
      "sync_class" => "lazy_but_guaranteed",
      "ownership" => "support",
      "dirty_after" => false
    )
  end

  def materialized_slot_descriptor_without_changed_files
    {
      "runtime_path" => "/agent/workspaces/Portal-42-runtime/repo-beta",
      "source_kind" => "local_git",
      "source_alias" => "member-portal-starters",
      "checkout" => "worktree_branch",
      "requested_ref" => "refs/heads/a3/work/Portal-42",
      "branch_ref" => "refs/heads/a3/work/Portal-42",
      "resolved_head" => "abc123",
      "dirty_before" => false,
      "dirty_after" => true,
      "access" => "read_write",
      "sync_class" => "eager",
      "ownership" => "edit_target"
    }
  end
end
