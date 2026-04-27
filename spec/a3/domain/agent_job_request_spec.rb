# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Domain::AgentJobRequest do
  let(:source_descriptor) do
    A3::Domain::SourceDescriptor.runtime_detached_commit(
      task_ref: "Sample#42",
      ref: "abc123"
    )
  end

  it "serializes the job contract without shell-specific command strings" do
    request = described_class.new(
      job_id: "job-sample-42-verification",
      task_ref: "Sample#42",
      phase: :verification,
      runtime_profile: "host-local-agent",
      source_descriptor: source_descriptor,
      working_dir: "/workspace/sample-catalog-service",
      command: "task",
      args: ["ops:flow:standard"],
      env: { A2O_ROOT_DIR: "/workspace" },
      timeout_seconds: 1800,
      artifact_rules: [
        {
          role: "junit",
          glob: "target/surefire-reports/*.xml",
          retention_class: "evidence"
        }
      ]
    )

    expect(request.request_form).to eq(
      "job_id" => "job-sample-42-verification",
      "task_ref" => "Sample#42",
      "phase" => "verification",
      "runtime_profile" => "host-local-agent",
      "source_descriptor" => source_descriptor.persisted_form,
      "working_dir" => "/workspace/sample-catalog-service",
      "command" => "task",
      "args" => ["ops:flow:standard"],
      "env" => { "A2O_ROOT_DIR" => "/workspace" },
      "timeout_seconds" => 1800,
      "artifact_rules" => [
        {
          "role" => "junit",
          "glob" => "target/surefire-reports/*.xml",
          "retention_class" => "evidence"
        }
      ]
    )
  end

  it "round-trips from the request form" do
    workspace_request = A3::Domain::AgentWorkspaceRequest.new(
      mode: :agent_materialized,
      workspace_kind: :ticket_workspace,
      workspace_id: "Sample-42-ticket",
      freshness_policy: :reuse_if_clean_and_ref_matches,
      cleanup_policy: :retain_until_a3_cleanup,
      slots: {
        repo_alpha: {
          source: { kind: "local_git", alias: "sample-catalog-service" },
          ref: "refs/heads/a2o/work/Sample-42",
          checkout: "worktree_branch",
          access: "read_write",
          sync_class: "eager",
          ownership: "edit_target",
          required: true
        }
      }
    )
    request = described_class.new(
      job_id: "job-sample-42-implementation",
      task_ref: "Sample#42",
      phase: "implementation",
      runtime_profile: "host-local",
      source_descriptor: A3::Domain::SourceDescriptor.implementation(task_ref: "Sample#42", ref: "feature/a3"),
      workspace_request: workspace_request,
      worker_protocol_request: {
        task_ref: "Sample#42",
        run_ref: "run-42",
        phase: "implementation"
      },
      agent_environment: {
        workspace_root: "/agent/workspaces",
        source_paths: {
          "sample-catalog-service" => "/agent/repos/starters"
        },
        env: {
          A2O_ROOT_DIR: "/agent/a2o"
        },
        required_bins: ["git", "task"]
      },
      working_dir: ".",
      command: "ruby",
      args: ["scripts/a3/worker.rb"],
      env: {},
      timeout_seconds: 600,
      artifact_rules: []
    )

    expect(request.request_form.fetch("workspace_request")).to eq(workspace_request.request_form)
    expect(request.request_form.fetch("worker_protocol_request")).to eq(
      "task_ref" => "Sample#42",
      "run_ref" => "run-42",
      "phase" => "implementation"
    )
    expect(request.request_form.fetch("agent_environment")).to eq(
      "workspace_root" => "/agent/workspaces",
      "source_paths" => {
        "sample-catalog-service" => "/agent/repos/starters"
      },
      "env" => {
        "A2O_ROOT_DIR" => "/agent/a2o"
      },
      "required_bins" => ["git", "task"]
    )
    expect(described_class.from_request_form(request.request_form)).to eq(request)
  end

  it "round-trips merge requests" do
    merge_request = {
      "workspace_id" => "merge-Sample-42",
      "policy" => "ff_only",
      "slots" => {
        "repo_alpha" => {
          "source" => {
            "kind" => "local_git",
            "alias" => "sample-catalog-service"
          },
          "source_ref" => "refs/heads/a2o/work/Sample-42",
          "target_ref" => "refs/heads/main"
        }
      }
    }
    request = described_class.new(
      job_id: "job-sample-42-merge",
      task_ref: "Sample#42",
      phase: :merge,
      runtime_profile: "host-local",
      source_descriptor: source_descriptor,
      merge_request: merge_request,
      working_dir: ".",
      command: "a2o-agent-merge",
      args: [],
      env: {},
      timeout_seconds: 600,
      artifact_rules: []
    )

    expect(request.request_form.fetch("merge_request")).to eq(merge_request)
    expect(described_class.from_request_form(request.request_form)).to eq(request)
  end

it "round-trips merge recovery requests" do
  merge_recovery_request = {
    "workspace_id" => "merge-Sample-42-run-merge-1",
    "slots" => {
      "repo_alpha" => {
        "runtime_path" => "/agent/workspaces/merge-Sample-42-run-merge-1/repo-alpha",
        "target_ref" => "refs/heads/main",
        "source_ref" => "refs/heads/a2o/work/Sample-42",
        "merge_before_head" => "abc123",
        "source_head_commit" => "def456",
        "conflict_files" => ["docs/conflict.md"],
        "commit_message" => "Recover Sample#42 merge"
      }
    }
  }
  request = described_class.new(
    job_id: "job-sample-42-merge-recovery",
    task_ref: "Sample#42",
    phase: :merge,
    runtime_profile: "host-local",
    source_descriptor: source_descriptor,
    merge_recovery_request: merge_recovery_request,
    working_dir: ".",
    command: "a2o-agent-merge-recovery",
    args: [],
    env: {},
    timeout_seconds: 600,
    artifact_rules: []
  )

  expect(request.request_form.fetch("merge_recovery_request")).to eq(merge_recovery_request)
  expect(described_class.from_request_form(request.request_form)).to eq(request)
end

  it "fails closed on unsupported phases and non-positive timeouts" do
    expect do
      described_class.new(
        job_id: "job-1",
        task_ref: "Sample#42",
        phase: :deploy,
        runtime_profile: "host-local",
        source_descriptor: source_descriptor,
        working_dir: ".",
        command: "task",
        args: [],
        env: {},
        timeout_seconds: 60,
        artifact_rules: []
      )
    end.to raise_error(A3::Domain::ConfigurationError, /unsupported agent job phase/)

    expect do
      described_class.new(
        job_id: "job-1",
        task_ref: "Sample#42",
        phase: :verification,
        runtime_profile: "host-local",
        source_descriptor: source_descriptor,
        working_dir: ".",
        command: "task",
        args: [],
        env: {},
        timeout_seconds: 0,
        artifact_rules: []
      )
    end.to raise_error(A3::Domain::ConfigurationError, /timeout_seconds/)
  end
end
