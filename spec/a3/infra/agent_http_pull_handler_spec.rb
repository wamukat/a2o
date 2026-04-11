# frozen_string_literal: true

require "digest"
require "spec_helper"

RSpec.describe A3::Infra::AgentHttpPullHandler do
  let(:tmpdir) { Dir.mktmpdir }
  let(:store) { A3::Infra::JsonAgentJobStore.new(File.join(tmpdir, "agent-jobs.json")) }
  let(:artifact_store) { A3::Infra::FileAgentArtifactStore.new(File.join(tmpdir, "agent-artifacts")) }
  let(:handler) { described_class.new(job_store: store, artifact_store: artifact_store, clock: -> { "2026-04-11T08:00:00Z" }) }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "exposes enqueue, pull, and result endpoints for an agent" do
    enqueue_response = handler.handle(
      method: "POST",
      path: "/v1/agent/jobs",
      body: JSON.generate(agent_job_request("job-1").request_form)
    )

    expect(enqueue_response.status).to eq(201)

    claim_response = handler.handle(
      method: "GET",
      path: "/v1/agent/jobs/next",
      query: {"agent" => "portal-dev-env"}
    )
    claimed_payload = JSON.parse(claim_response.body)

    expect(claim_response.status).to eq(200)
    expect(claimed_payload.fetch("job").fetch("job_id")).to eq("job-1")

    idle_response = handler.handle(
      method: "GET",
      path: "/v1/agent/jobs/next",
      query: {"agent" => "portal-dev-env"}
    )
    expect(idle_response.status).to eq(204)

    result_response = handler.handle(
      method: "POST",
      path: "/v1/agent/jobs/job-1/result",
      body: JSON.generate(agent_job_result("job-1").result_form)
    )

    expect(result_response.status).to eq(200)
    expect(store.fetch("job-1")).to have_attributes(state: :completed)
  end

  it "fetches a job record by id" do
    store.enqueue(agent_job_request("job-1"))

    response = handler.handle(
      method: "GET",
      path: "/v1/agent/jobs/job-1"
    )

    expect(response.status).to eq(200)
    payload = JSON.parse(response.body)
    expect(payload.fetch("job")).to include(
      "state" => "queued"
    )
    expect(payload.fetch("job").fetch("request")).to include(
      "job_id" => "job-1"
    )
  end

  it "rejects local path based result payloads" do
    store.enqueue(agent_job_request("job-1"))
    store.claim_next(agent_name: "portal-dev-env", claimed_at: "2026-04-11T08:00:00Z")
    payload = agent_job_result("job-1").result_form.merge(
      "combined_log" => "/tmp/combined.log",
      "artifacts" => ["/tmp/report.xml"]
    )

    response = handler.handle(
      method: "POST",
      path: "/v1/agent/jobs/job-1/result",
      body: JSON.generate(payload)
    )

    expect(response.status).to eq(400)
    expect(JSON.parse(response.body).fetch("error")).to include("upload references")
  end

  it "requires an agent name when pulling jobs" do
    response = handler.handle(
      method: "GET",
      path: "/v1/agent/jobs/next",
      query: {}
    )

    expect(response.status).to eq(400)
    expect(JSON.parse(response.body).fetch("error")).to include("missing query parameter: agent")
  end

  it "requires a bearer token when configured" do
    secured_handler = described_class.new(
      job_store: store,
      artifact_store: artifact_store,
      auth_token: "secret-token"
    )

    unauthorized_response = secured_handler.handle(
      method: "GET",
      path: "/v1/agent/jobs/next",
      query: {"agent" => "portal-dev-env"}
    )
    authorized_response = secured_handler.handle(
      method: "GET",
      path: "/v1/agent/jobs/next",
      query: {"agent" => "portal-dev-env"},
      headers: {"authorization" => "Bearer secret-token"}
    )

    expect(unauthorized_response.status).to eq(401)
    expect(authorized_response.status).to eq(204)
  end

  it "separates control-plane and agent bearer token scopes when both are configured" do
    secured_handler = described_class.new(
      job_store: store,
      artifact_store: artifact_store,
      auth_token: "agent-token",
      control_auth_token: "control-token"
    )

    agent_enqueue_response = secured_handler.handle(
      method: "POST",
      path: "/v1/agent/jobs",
      body: JSON.generate(agent_job_request("job-1").request_form),
      headers: {"authorization" => "Bearer agent-token"}
    )
    control_enqueue_response = secured_handler.handle(
      method: "POST",
      path: "/v1/agent/jobs",
      body: JSON.generate(agent_job_request("job-1").request_form),
      headers: {"authorization" => "Bearer control-token"}
    )
    control_claim_response = secured_handler.handle(
      method: "GET",
      path: "/v1/agent/jobs/next",
      query: {"agent" => "portal-dev-env"},
      headers: {"authorization" => "Bearer control-token"}
    )
    agent_claim_response = secured_handler.handle(
      method: "GET",
      path: "/v1/agent/jobs/next",
      query: {"agent" => "portal-dev-env"},
      headers: {"authorization" => "Bearer agent-token"}
    )

    expect(agent_enqueue_response.status).to eq(401)
    expect(control_enqueue_response.status).to eq(201)
    expect(control_claim_response.status).to eq(401)
    expect(agent_claim_response.status).to eq(200)
  end

  it "accepts artifact uploads into the configured artifact store" do
    content = "verification log\n"
    digest = "sha256:#{Digest::SHA256.hexdigest(content)}"

    response = handler.handle(
      method: "PUT",
      path: "/v1/agent/artifacts/art-log-1",
      query: {
        "role" => "combined-log",
        "digest" => digest,
        "byte_size" => content.bytesize.to_s,
        "retention_class" => "diagnostic",
        "media_type" => "text/plain"
      },
      body: content
    )

    expect(response.status).to eq(201)
    expect(JSON.parse(response.body).fetch("artifact")).to include(
      "artifact_id" => "art-log-1",
      "digest" => digest
    )
    expect(artifact_store.read("art-log-1")).to eq(content)
  end

  def agent_job_request(job_id)
    A3::Domain::AgentJobRequest.new(
      job_id: job_id,
      task_ref: "Portal#42",
      phase: :verification,
      runtime_profile: "portal-dev-env",
      source_descriptor: source_descriptor,
      working_dir: "/workspace/member-portal-starters",
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
      log_uploads: [
        {
          "artifact_id" => "art-log-1",
          "role" => "combined-log",
          "digest" => "sha256:abc",
          "byte_size" => 128,
          "retention_class" => "diagnostic"
        }
      ],
      artifact_uploads: [],
      workspace_descriptor: workspace_descriptor,
      heartbeat: nil
    )
  end

  def source_descriptor
    A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Portal#42", ref: "abc123")
  end

  def workspace_descriptor
    A3::Domain::AgentWorkspaceDescriptor.new(
      workspace_kind: :runtime_workspace,
      runtime_profile: "portal-dev-env",
      workspace_id: "workspace-portal-42",
      source_descriptor: source_descriptor,
      slot_descriptors: {}
    )
  end
end
