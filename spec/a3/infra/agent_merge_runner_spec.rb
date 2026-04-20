# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Infra::AgentMergeRunner do
  FakeMergeClient = Struct.new(:records, :on_fetch, :base_url, keyword_init: true) do
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

  let(:client) { FakeMergeClient.new(records: {}, base_url: "http://127.0.0.1:7393") }
  let(:runner) do
    described_class.new(
      control_plane_client: client,
      runtime_profile: "host-local",
      source_aliases: { repo_alpha: "sample-catalog-service" },
      poll_interval_seconds: 0,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_seconds) {}
    )
  end
  let(:merge_plan) do
    A3::Domain::MergePlan.new(
      task_ref: "Sample#42",
      run_ref: "run-merge-1",
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a2o/work/Sample-42"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/main", bootstrap_ref: nil),
      merge_policy: :ff_only,
      merge_slots: [:repo_alpha]
    )
  end
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-workspace",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Sample#42", ref: "refs/heads/main"),
      slot_paths: {}
    )
  end

  it "enqueues an agent merge job and validates merge evidence" do
    client.on_fetch = lambda do |job_id|
      client.complete(job_id, agent_result(job_id, workspace_descriptor(
        "repo_alpha" => {
          "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha",
          "source_kind" => "local_git",
          "source_alias" => "sample-catalog-service",
          "merge_source_ref" => "refs/heads/a2o/work/Sample-42",
          "merge_target_ref" => "refs/heads/main",
          "merge_policy" => "ff_only",
          "merge_before_head" => "abc123",
          "merge_after_head" => "def456",
          "resolved_head" => "def456",
          "merge_status" => "merged",
          "project_repo_mutator" => "a2o-agent"
        }
      )))
    end

    execution = runner.run(merge_plan, workspace: workspace)

    request = client.records.values.first.request
    expect(request.phase).to eq(:merge)
    expect(request.command).to eq("a3-agent-merge")
    expect(request.merge_request).to include(
      "workspace_id" => "merge-Sample-42-run-merge-1",
      "policy" => "ff_only"
    )
    expect(request.merge_request.fetch("slots").fetch("repo_alpha")).to include(
      "source_ref" => "refs/heads/a2o/work/Sample-42",
      "target_ref" => "refs/heads/main"
    )
    expect(execution).to have_attributes(success?: true)
    expect(execution.diagnostics.fetch("merged_slots")).to eq(
      [
        {
          "slot" => "repo_alpha",
          "target_ref" => "refs/heads/main",
          "before_head" => "abc123",
          "after_head" => "def456"
        }
      ]
    )
  end

  it "rejects missing agent merge evidence" do
    client.on_fetch = lambda do |job_id|
      client.complete(job_id, agent_result(job_id, workspace_descriptor(
        "repo_alpha" => {
          "merge_source_ref" => "refs/heads/a2o/work/Sample-42",
          "merge_target_ref" => "refs/heads/main",
          "merge_status" => "prepared"
        }
      )))
    end

    execution = runner.run(merge_plan, workspace: workspace)

    expect(execution).to have_attributes(
      success?: false,
      failing_command: "agent_merge_evidence",
      observed_state: "agent_merge_evidence_invalid"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("repo_alpha.merge_status must be merged")
  end

  it "surfaces conflicted agent merge evidence as a merge recovery candidate" do
    client.on_fetch = lambda do |job_id|
      client.complete(job_id, agent_result(
        job_id,
        workspace_descriptor(
          "repo_alpha" => {
            "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha",
            "source_alias" => "sample-catalog-service",
            "merge_source_ref" => "refs/heads/a2o/work/Sample-42",
            "merge_target_ref" => "refs/heads/main",
            "merge_policy" => "ff_or_merge",
            "merge_before_head" => "abc123",
            "source_head_commit" => "def456",
            "merge_status" => "conflicted",
            "merge_recovery_candidate" => true,
            "merge_recovery_workspace_retained" => true,
            "conflict_files" => ["docs/conflict.md"],
            "resolved_conflict_files" => []
          }
        ),
        status: :failed,
        exit_code: 1,
        summary: "merge conflicted"
      ))
    end

    execution = runner.run(merge_plan, workspace: workspace)

    expect(execution).to have_attributes(
      success?: false,
      failing_command: "agent_merge_job",
      observed_state: "merge_recovery_candidate"
    )
    recovery = execution.diagnostics.fetch("merge_recovery")
    expect(recovery).to include(
      "required" => true,
      "recovery_id" => "merge-recovery-merge-run-merge-1-job-1",
      "merge_run_ref" => "run-merge-1",
      "target_ref" => "refs/heads/main",
      "source_ref" => "refs/heads/a2o/work/Sample-42",
      "merge_before_head" => "abc123",
      "source_head_commit" => "def456",
      "conflict_files" => ["docs/conflict.md"],
      "resolved_conflict_files" => [],
      "worker_result_ref" => nil,
      "changed_files" => [],
      "marker_scan_result" => nil,
      "verification_run_ref" => nil,
      "publish_before_head" => nil,
      "publish_after_head" => nil,
      "status" => "failed"
    )
    expect(recovery.fetch("slots")).to contain_exactly(
      include(
        "slot" => "repo_alpha",
        "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha",
        "target_ref" => "refs/heads/main",
        "source_ref" => "refs/heads/a2o/work/Sample-42",
        "merge_before_head" => "abc123",
        "source_head_commit" => "def456",
        "conflict_files" => ["docs/conflict.md"],
        "resolved_conflict_files" => []
      )
    )
    expect(execution.response_bundle.fetch("merge_recovery")).to eq(recovery)
    expect(execution.response_bundle.fetch("merge_recovery_required")).to be(true)
  end

  it "runs merge recovery worker and finalizer for recoverable conflicts" do
    sequence = 0
    recovery_runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "host-local",
      source_aliases: { repo_alpha: "sample-catalog-service" },
      poll_interval_seconds: 0,
      job_id_generator: -> {
        sequence += 1
        "job-#{sequence}"
      },
      sleeper: ->(_seconds) {},
      merge_recovery_command: "a3-merge-recovery-worker",
      merge_recovery_args: ["--resolve"],
      merge_recovery_env: { "A3_EXTRA" => "1" }
    )

    client.on_fetch = lambda do |job_id|
      request = client.records.fetch(job_id).request
      case request.command
      when "a3-agent-merge"
        client.complete(job_id, agent_result(
          job_id,
          workspace_descriptor(
            "repo_alpha" => {
              "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha",
              "source_alias" => "sample-catalog-service",
              "merge_source_ref" => "refs/heads/a2o/work/Sample-42",
              "merge_target_ref" => "refs/heads/main",
              "merge_policy" => "ff_or_merge",
              "merge_before_head" => "abc123",
              "source_head_commit" => "def456",
              "merge_status" => "conflicted",
              "merge_recovery_candidate" => true,
              "conflict_files" => ["docs/conflict.md"],
              "resolved_conflict_files" => []
            }
          ),
          status: :failed,
          exit_code: 1,
          summary: "merge conflicted"
        ))
      when "a3-merge-recovery-worker"
        payload = JSON.parse(request.env.fetch("A3_MERGE_RECOVERY"))
        expect(payload).to include(
          "recovery_id" => "merge-recovery-merge-run-merge-1-job-1",
          "conflict_files" => ["docs/conflict.md"]
        )
        expect(request.working_dir).to eq("/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha")
        expect(request.args).to eq(["--resolve"])
        expect(request.env.fetch("A3_EXTRA")).to eq("1")
        client.complete(job_id, agent_result(job_id, workspace_descriptor({}), summary: "recovery worker resolved conflict"))
      when "a3-agent-merge-recovery"
        expect(request.merge_recovery_request).to eq(
          "workspace_id" => "merge-recovery-merge-run-merge-1-job-1",
          "slots" => {
            "repo_alpha" => {
              "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha",
              "target_ref" => "refs/heads/main",
              "source_ref" => "refs/heads/a2o/work/Sample-42",
              "merge_before_head" => "abc123",
              "source_head_commit" => "def456",
              "conflict_files" => ["docs/conflict.md"],
              "commit_message" => "A2O merge recovery Sample#42 run-merge-1"
            }
          }
        )
        client.complete(job_id, agent_result(job_id, workspace_descriptor(
          "repo_alpha" => {
            "merge_status" => "recovered",
            "publish_before_head" => "abc123",
            "publish_after_head" => "fedcba",
            "merge_after_head" => "fedcba",
            "resolved_head" => "fedcba",
            "resolved_conflict_files" => ["docs/conflict.md"],
            "changed_files" => ["docs/conflict.md"],
            "marker_scan_result" => {
              "scanner" => "a2o-agent-conflict-marker-scan",
              "unresolved_files" => []
            }
          }
        ), summary: "merge recovery finalized"))
      else
        raise "unexpected command: #{request.command}"
      end
    end

    execution = recovery_runner.run(merge_plan, workspace: workspace)

    expect(execution).to have_attributes(success?: true)
    expect(client.records.values.map { |record| record.request.command }).to eq(
      ["a3-agent-merge", "a3-merge-recovery-worker", "a3-agent-merge-recovery"]
    )
    recovery = execution.diagnostics.fetch("merge_recovery")
    expect(recovery).to include(
      "worker_result_ref" => "merge-recovery-worker-run-merge-1-job-2",
      "status" => "recovered",
      "changed_files" => ["docs/conflict.md"],
      "publish_before_head" => "abc123",
      "publish_after_head" => "fedcba",
      "resolved_conflict_files" => ["docs/conflict.md"]
    )
    expect(execution.response_bundle.fetch("merge_recovery_required")).to be(false)
  end


  it "recovers a Sample#245-style validation docs conflict before verification" do
    sequence = 0
    sample_merge_plan = A3::Domain::MergePlan.new(
      task_ref: "Sample#245",
      run_ref: "run-merge-245",
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a2o/work/Sample-245"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/main", bootstrap_ref: nil),
      merge_policy: :ff_or_merge,
      merge_slots: [:repo_alpha]
    )
    sample_workspace = A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-workspace/Sample-245",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Sample#245", ref: "refs/heads/main"),
      slot_paths: {}
    )
    recovery_runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "host-local",
      source_aliases: { repo_alpha: "sample-catalog-service" },
      poll_interval_seconds: 0,
      job_id_generator: -> {
        sequence += 1
        "job-#{sequence}"
      },
      sleeper: ->(_seconds) {},
      merge_recovery_command: "a3-merge-recovery-worker"
    )

    client.on_fetch = lambda do |job_id|
      request = client.records.fetch(job_id).request
      case request.command
      when "a3-agent-merge"
        client.complete(job_id, agent_result(
          job_id,
          workspace_descriptor(
            {
              "repo_alpha" => {
                "runtime_path" => "/agent/workspaces/merge-Sample-245-run-merge-245/repo_alpha",
                "source_alias" => "sample-catalog-service",
                "merge_source_ref" => "refs/heads/a2o/work/Sample-245",
                "merge_target_ref" => "refs/heads/main",
                "merge_policy" => "ff_or_merge",
                "merge_before_head" => "base245",
                "source_head_commit" => "source245",
                "merge_status" => "conflicted",
                "merge_recovery_candidate" => true,
                "conflict_files" => ["docs/10-ops/validation.md"],
                "resolved_conflict_files" => []
              }
            },
            workspace_id: "merge-Sample-245-run-merge-245",
            task_ref: "Sample#245"
          ),
          status: :failed,
          exit_code: 1,
          summary: "Sample#245 validation docs conflict"
        ))
      when "a3-merge-recovery-worker"
        expect(JSON.parse(request.env.fetch("A3_MERGE_RECOVERY"))).to include(
          "target_ref" => "refs/heads/main",
          "source_ref" => "refs/heads/a2o/work/Sample-245",
          "conflict_files" => ["docs/10-ops/validation.md"]
        )
        client.complete(job_id, agent_result(job_id, workspace_descriptor({}, workspace_id: "merge-Sample-245-run-merge-245", task_ref: "Sample#245"), summary: "resolved Sample#245 validation docs conflict"))
      when "a3-agent-merge-recovery"
        expect(request.merge_recovery_request.fetch("slots").fetch("repo_alpha")).to include(
          "runtime_path" => "/agent/workspaces/merge-Sample-245-run-merge-245/repo_alpha",
          "conflict_files" => ["docs/10-ops/validation.md"]
        )
        client.complete(job_id, agent_result(job_id, workspace_descriptor(
          {
            "repo_alpha" => {
              "merge_status" => "recovered",
              "publish_before_head" => "base245",
              "publish_after_head" => "resolved245",
              "merge_after_head" => "resolved245",
              "resolved_head" => "resolved245",
              "resolved_conflict_files" => ["docs/10-ops/validation.md"],
              "changed_files" => ["docs/10-ops/validation.md"],
              "marker_scan_result" => { "scanner" => "a2o-agent-conflict-marker-scan", "unresolved_files" => [] }
            }
          },
          workspace_id: "merge-Sample-245-run-merge-245",
          task_ref: "Sample#245"
        ), summary: "Sample#245 recovery finalized"))
      else
        raise "unexpected command: #{request.command}"
      end
    end

    execution = recovery_runner.run(sample_merge_plan, workspace: sample_workspace)

    expect(execution).to have_attributes(success?: true)
    recovery = execution.diagnostics.fetch("merge_recovery")
    expect(recovery).to include(
      "status" => "recovered",
      "target_ref" => "refs/heads/main",
      "source_ref" => "refs/heads/a2o/work/Sample-245",
      "conflict_files" => ["docs/10-ops/validation.md"],
      "changed_files" => ["docs/10-ops/validation.md"],
      "publish_before_head" => "base245",
      "publish_after_head" => "resolved245"
    )
    expect(execution.response_bundle).to include(
      "merge_recovery_required" => false,
      "merge_recovery_verification_required" => true,
      "merge_recovery_verification_source_ref" => "refs/heads/main"
    )
  end

  it "keeps merge recovery retryable when recovery worker enqueue fails" do
    recovery_runner = described_class.new(
      control_plane_client: client,
      runtime_profile: "host-local",
      source_aliases: { repo_alpha: "sample-catalog-service" },
      poll_interval_seconds: 0,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_seconds) {},
      merge_recovery_command: "a3-merge-recovery-worker"
    )
    allow(client).to receive(:enqueue).and_wrap_original do |original, request|
      raise "agent unavailable" if request.command == "a3-merge-recovery-worker"

      original.call(request)
    end
    client.on_fetch = lambda do |job_id|
      client.complete(job_id, agent_result(
        job_id,
        workspace_descriptor(
          "repo_alpha" => {
            "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha",
            "merge_source_ref" => "refs/heads/a2o/work/Sample-42",
            "merge_target_ref" => "refs/heads/main",
            "merge_before_head" => "abc123",
            "source_head_commit" => "def456",
            "merge_status" => "conflicted",
            "merge_recovery_candidate" => true,
            "conflict_files" => ["docs/conflict.md"]
          }
        ),
        status: :failed,
        exit_code: 1,
        summary: "merge conflicted"
      ))
    end

    execution = recovery_runner.run(merge_plan, workspace: workspace)

    expect(execution).to have_attributes(
      success?: false,
      failing_command: "agent_merge_recovery_worker_enqueue",
      observed_state: "merge_recovery_candidate"
    )
    expect(execution.response_bundle.fetch("merge_recovery_required")).to be(true)
  end

  it "rejects recovered merge evidence with unresolved marker scan" do
    candidate = {
      "recovery_id" => "merge-recovery-1",
      "slots" => [
        {
          "slot" => "repo_alpha",
          "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha",
          "target_ref" => "refs/heads/main",
          "source_ref" => "refs/heads/a2o/work/Sample-42",
          "merge_before_head" => "abc123",
          "source_head_commit" => "def456",
          "conflict_files" => ["docs/conflict.md"],
          "resolved_conflict_files" => []
        }
      ]
    }
    worker_result = agent_result("worker-job", workspace_descriptor({}))
    finalizer_result = agent_result("finalizer-job", workspace_descriptor(
      "repo_alpha" => {
        "merge_status" => "recovered",
        "publish_before_head" => "abc123",
        "publish_after_head" => "fedcba",
        "merge_after_head" => "fedcba",
        "resolved_head" => "fedcba",
        "resolved_conflict_files" => ["docs/conflict.md"],
        "changed_files" => ["docs/conflict.md"],
        "marker_scan_result" => {
          "scanner" => "a3-agent-conflict-marker-scan",
          "unresolved_files" => ["docs/conflict.md"]
        }
      }
    ))

    execution = runner.send(:validate_merge_recovery_evidence, candidate, worker_result, finalizer_result)

    expect(execution).to have_attributes(
      success?: false,
      failing_command: "agent_merge_recovery_evidence",
      observed_state: "merge_recovery_evidence_invalid"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("repo_alpha.marker_scan_result must report no unresolved files")
  end

  it "rejects extra merge slot descriptors" do
    client.on_fetch = lambda do |job_id|
      client.complete(job_id, agent_result(job_id, workspace_descriptor(
        "repo_alpha" => {
          "merge_source_ref" => "refs/heads/a2o/work/Sample-42",
          "merge_target_ref" => "refs/heads/main",
          "merge_policy" => "ff_only",
          "merge_before_head" => "abc123",
          "merge_after_head" => "def456",
          "resolved_head" => "def456",
          "merge_status" => "merged",
          "project_repo_mutator" => "a2o-agent"
        },
        "repo_beta" => {
          "merge_status" => "merged"
        }
      )))
    end

    execution = runner.run(merge_plan, workspace: workspace)

    expect(execution).to have_attributes(
      success?: false,
      failing_command: "agent_merge_evidence"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("slot descriptors must match merge slots")
  end

  it "rejects merge evidence from a different source alias" do
    client.on_fetch = lambda do |job_id|
      client.complete(job_id, agent_result(job_id, workspace_descriptor(
        "repo_alpha" => {
          "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo_alpha",
          "source_alias" => "wrong-repo",
          "merge_source_ref" => "refs/heads/a2o/work/Sample-42",
          "merge_target_ref" => "refs/heads/main",
          "merge_policy" => "ff_only",
          "merge_before_head" => "abc123",
          "merge_after_head" => "def456",
          "resolved_head" => "def456",
          "merge_status" => "merged",
          "project_repo_mutator" => "a2o-agent"
        }
      )))
    end

    execution = runner.run(merge_plan, workspace: workspace)

    expect(execution).to have_attributes(
      success?: false,
      failing_command: "agent_merge_evidence"
    )
    expect(execution.diagnostics.fetch("validation_errors")).to include("repo_alpha.source_alias must match configured agent source alias")
  end

  def agent_result(job_id, workspace_descriptor, status: :succeeded, exit_code: 0, summary: "merge succeeded")
    A3::Domain::AgentJobResult.new(
      job_id: job_id,
      status: status,
      exit_code: exit_code,
      started_at: "2026-04-12T00:00:00Z",
      finished_at: "2026-04-12T00:00:01Z",
      summary: summary,
      log_uploads: [],
      artifact_uploads: [],
      workspace_descriptor: workspace_descriptor,
      heartbeat: "2026-04-12T00:00:01Z"
    )
  end

  def workspace_descriptor(slot_descriptors = {}, workspace_id: "merge-Sample-42-run-merge-1", task_ref: "Sample#42", **slot_descriptor_keywords)
    slot_descriptors = slot_descriptor_keywords.transform_keys(&:to_s) unless slot_descriptor_keywords.empty?

    A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      runtime_profile: "host-local",
      workspace_id: workspace_id,
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: task_ref, ref: "refs/heads/main"),
      slot_descriptors: slot_descriptors
    )
  end
end
