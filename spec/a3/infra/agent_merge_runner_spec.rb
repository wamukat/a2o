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
      source_aliases: { repo_alpha: "member-portal-starters" },
      poll_interval_seconds: 0,
      job_id_generator: -> { "job-1" },
      sleeper: ->(_seconds) {}
    )
  end
  let(:merge_plan) do
    A3::Domain::MergePlan.new(
      task_ref: "Portal#42",
      run_ref: "run-merge-1",
      merge_source: A3::Domain::MergeSource.new(source_ref: "refs/heads/a3/work/Portal-42"),
      integration_target: A3::Domain::IntegrationTarget.new(target_ref: "refs/heads/main", bootstrap_ref: nil),
      merge_policy: :ff_only,
      merge_slots: [:repo_alpha]
    )
  end
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: "/tmp/a3-workspace",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Portal#42", ref: "refs/heads/main"),
      slot_paths: {}
    )
  end

  it "enqueues an agent merge job and validates merge evidence" do
    client.on_fetch = lambda do |job_id|
      client.complete(job_id, agent_result(job_id, workspace_descriptor(
        "repo_alpha" => {
          "runtime_path" => "/agent/workspaces/merge-Portal-42-run-merge-1/repo-alpha",
          "source_kind" => "local_git",
          "source_alias" => "member-portal-starters",
          "merge_source_ref" => "refs/heads/a3/work/Portal-42",
          "merge_target_ref" => "refs/heads/main",
          "merge_policy" => "ff_only",
          "merge_before_head" => "abc123",
          "merge_after_head" => "def456",
          "resolved_head" => "def456",
          "merge_status" => "merged",
          "project_repo_mutator" => "a3-agent"
        }
      )))
    end

    execution = runner.run(merge_plan, workspace: workspace)

    request = client.records.values.first.request
    expect(request.phase).to eq(:merge)
    expect(request.command).to eq("a3-agent-merge")
    expect(request.merge_request).to include(
      "workspace_id" => "merge-Portal-42-run-merge-1",
      "policy" => "ff_only"
    )
    expect(request.merge_request.fetch("slots").fetch("repo_alpha")).to include(
      "source_ref" => "refs/heads/a3/work/Portal-42",
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
          "merge_source_ref" => "refs/heads/a3/work/Portal-42",
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

  it "rejects extra merge slot descriptors" do
    client.on_fetch = lambda do |job_id|
      client.complete(job_id, agent_result(job_id, workspace_descriptor(
        "repo_alpha" => {
          "merge_source_ref" => "refs/heads/a3/work/Portal-42",
          "merge_target_ref" => "refs/heads/main",
          "merge_policy" => "ff_only",
          "merge_before_head" => "abc123",
          "merge_after_head" => "def456",
          "resolved_head" => "def456",
          "merge_status" => "merged",
          "project_repo_mutator" => "a3-agent"
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
          "runtime_path" => "/agent/workspaces/merge-Portal-42-run-merge-1/repo-alpha",
          "source_alias" => "wrong-repo",
          "merge_source_ref" => "refs/heads/a3/work/Portal-42",
          "merge_target_ref" => "refs/heads/main",
          "merge_policy" => "ff_only",
          "merge_before_head" => "abc123",
          "merge_after_head" => "def456",
          "resolved_head" => "def456",
          "merge_status" => "merged",
          "project_repo_mutator" => "a3-agent"
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

  def agent_result(job_id, workspace_descriptor)
    A3::Domain::AgentJobResult.new(
      job_id: job_id,
      status: :succeeded,
      exit_code: 0,
      started_at: "2026-04-12T00:00:00Z",
      finished_at: "2026-04-12T00:00:01Z",
      summary: "merge succeeded",
      log_uploads: [],
      artifact_uploads: [],
      workspace_descriptor: workspace_descriptor,
      heartbeat: "2026-04-12T00:00:01Z"
    )
  end

  def workspace_descriptor(slot_descriptors)
    A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      runtime_profile: "host-local",
      workspace_id: "merge-Portal-42-run-merge-1",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Portal#42", ref: "refs/heads/main"),
      slot_descriptors: slot_descriptors
    )
  end
end
