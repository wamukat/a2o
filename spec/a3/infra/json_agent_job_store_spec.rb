# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Infra::JsonAgentJobStore do
  let(:tmpdir) { Dir.mktmpdir }
  let(:store) { described_class.new(File.join(tmpdir, "agent-jobs.json")) }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "enqueues, claims, persists, and completes an agent job" do
    request = agent_job_request("job-1")

    store.enqueue(request)
    claimed = store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:00:00Z")

    expect(claimed.request).to eq(request)
    expect(claimed.state).to eq(:claimed)
    expect(claimed.claimed_by).to eq("host-local-agent")
    expect(store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:00:01Z")).to be_nil

    result = agent_job_result("job-1")
    completed = store.complete(result)

    expect(completed.state).to eq(:completed)
    expect(completed.result).to eq(result)
    expect(described_class.new(File.join(tmpdir, "agent-jobs.json")).fetch("job-1")).to eq(completed)
  end

  it "rejects duplicate jobs" do
    request = agent_job_request("job-1")
    store.enqueue(request)

    expect do
      store.enqueue(request)
    end.to raise_error(A3::Domain::ConfigurationError, /already exists/)
  end

  def agent_job_request(job_id)
    A3::Domain::AgentJobRequest.new(
      job_id: job_id,
      task_ref: "Sample#42",
      phase: :verification,
      runtime_profile: "host-local-agent",
      source_descriptor: source_descriptor,
      working_dir: "/workspace/sample-catalog-service",
      command: "task",
      args: ["ops:flow:standard"],
      env: {},
      timeout_seconds: 1800,
      artifact_rules: []
    )
  end

  def agent_job_result(job_id)
    A3::Domain::AgentJobResult.new(
      job_id: job_id,
      status: :succeeded,
      exit_code: 0,
      started_at: "2026-04-11T08:00:00Z",
      finished_at: "2026-04-11T08:01:00Z",
      summary: "all checks passed",
      log_uploads: [],
      artifact_uploads: [],
      workspace_descriptor: workspace_descriptor,
      heartbeat: nil
    )
  end

  def source_descriptor
    A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Sample#42", ref: "abc123")
  end

  def workspace_descriptor
    A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      runtime_profile: "host-local-agent",
      workspace_id: "workspace-sample-42",
      source_descriptor: source_descriptor,
      slot_descriptors: {}
    )
  end
end
