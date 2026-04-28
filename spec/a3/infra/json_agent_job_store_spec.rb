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
    heartbeated = store.heartbeat(job_id: "job-1", heartbeat_at: "2026-04-11T08:00:30Z")

    expect(heartbeated.state).to eq(:claimed)
    expect(heartbeated.heartbeat_at).to eq("2026-04-11T08:00:30Z")

    result = agent_job_result("job-1")
    completed = store.complete(result)

    expect(completed.state).to eq(:completed)
    expect(completed.result).to eq(result)
    expect(completed.heartbeat_at).to eq("2026-04-11T08:00:30Z")
    expect(described_class.new(File.join(tmpdir, "agent-jobs.json")).fetch("job-1")).to eq(completed)
  end

  it "rejects duplicate jobs" do
    request = agent_job_request("job-1")
    store.enqueue(request)

    expect do
      store.enqueue(request)
    end.to raise_error(A3::Domain::ConfigurationError, /already exists/)
  end

  it "keeps completed results stable when heartbeat and result updates race across store instances" do
    request = agent_job_request("job-1")
    store.enqueue(request)
    store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:00:00Z")

    result_store = described_class.new(File.join(tmpdir, "agent-jobs.json"))
    heartbeat_store = described_class.new(File.join(tmpdir, "agent-jobs.json"))
    result = agent_job_result("job-1")

    threads = [
      Thread.new { 20.times { result_store.complete(result) } },
      Thread.new { 20.times { heartbeat_store.heartbeat(job_id: "job-1", heartbeat_at: "2026-04-11T08:00:30Z") } }
    ]
    threads.each(&:join)

    fetched = store.fetch("job-1")
    expect(fetched.state).to eq(:completed)
    expect(fetched.result).to eq(result)
  end

  it "marks a claimed job stale and ignores late heartbeat/result writes" do
    request = agent_job_request("job-1")
    store.enqueue(request)
    store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:00:00Z")

    stale = store.mark_stale(job_id: "job-1", reason: "runtime process stopped")
    expect(stale.state).to eq(:stale)
    expect(stale.stale_reason).to eq("runtime process stopped")

    expect(store.heartbeat(job_id: "job-1", heartbeat_at: "2026-04-11T08:00:30Z").state).to eq(:stale)
    expect(store.complete(agent_job_result("job-1")).state).to eq(:stale)
    expect(store.fetch("job-1").result).to be_nil
  end

  it "does not claim stale jobs" do
    request = agent_job_request("job-1")
    store.enqueue(request)
    store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:00:00Z")
    store.mark_stale(job_id: "job-1", reason: "runtime process stopped")

    expect(store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:01:00Z")).to be_nil
  end

  it "filters claimed jobs by project key when the agent session is project-bound" do
    store.enqueue(agent_job_request("job-a", project_key: "a2o"))
    store.enqueue(agent_job_request("job-b", project_key: "portal"))

    claimed = store.claim_next(agent_name: "portal-agent", claimed_at: "2026-04-11T08:00:00Z", project_key: "portal")

    expect(claimed.job_id).to eq("job-b")
    expect(claimed.project_key).to eq("portal")
    expect(store.fetch("job-a").state).to eq(:queued)
  end

  it "rejects projectless claims in multi-project mode" do
    store.enqueue(agent_job_request("job-a", project_key: "a2o"))

    with_env("A2O_MULTI_PROJECT_MODE" => "1") do
      expect do
        store.claim_next(agent_name: "unbound-agent", claimed_at: "2026-04-11T08:00:00Z")
      end.to raise_error(A3::Domain::ConfigurationError, /requires project_key in multi-project mode/)
    end
    expect(store.fetch("job-a").state).to eq(:queued)
  end

  it "persists project identity at the agent job record boundary" do
    request = agent_job_request("job-1", project_key: "a2o")

    store.enqueue(request)
    claimed = store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:00:00Z")
    completed = store.complete(agent_job_result("job-1", project_key: "a2o"))

    raw_record = JSON.parse(File.read(File.join(tmpdir, "agent-jobs.json"))).fetch("job-1")
    expect(raw_record.fetch("project_key")).to eq("a2o")
    expect(raw_record.fetch("request").fetch("project_key")).to eq("a2o")
    expect(raw_record.fetch("result").fetch("project_key")).to eq("a2o")
    expect(raw_record.fetch("result").fetch("workspace_descriptor").fetch("project_key")).to eq("a2o")
    expect(claimed.project_key).to eq("a2o")
    expect(completed.project_key).to eq("a2o")
    expect(described_class.new(File.join(tmpdir, "agent-jobs.json")).fetch("job-1")).to eq(completed)
  end

  it "rejects project identity mismatches between job requests and results" do
    request = agent_job_request("job-1", project_key: "a2o")
    store.enqueue(request)
    store.claim_next(agent_name: "host-local-agent", claimed_at: "2026-04-11T08:00:00Z")

    expect do
      store.complete(agent_job_result("job-1", project_key: "other"))
    end.to raise_error(A3::Domain::ConfigurationError, /project_key mismatch/)
  end

  def agent_job_request(job_id, project_key: nil)
    A3::Domain::AgentJobRequest.new(
      job_id: job_id,
      project_key: project_key,
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

  def agent_job_result(job_id, project_key: nil)
    A3::Domain::AgentJobResult.new(
      job_id: job_id,
      project_key: project_key,
      status: :succeeded,
      exit_code: 0,
      started_at: "2026-04-11T08:00:00Z",
      finished_at: "2026-04-11T08:01:00Z",
      summary: "all checks passed",
      log_uploads: [],
      artifact_uploads: [],
      workspace_descriptor: workspace_descriptor(project_key: project_key),
      heartbeat: nil
    )
  end

  def source_descriptor
    A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Sample#42", ref: "abc123")
  end

  def workspace_descriptor(project_key: nil)
    A3::Domain::AgentWorkspaceDescriptor.new(
      project_key: project_key,
      workspace_kind: :runtime_workspace,
      runtime_profile: "host-local-agent",
      workspace_id: "workspace-sample-42",
      source_descriptor: source_descriptor,
      slot_descriptors: {}
    )
  end
end
