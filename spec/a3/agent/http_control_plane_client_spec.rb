# frozen_string_literal: true

require "digest"
require "spec_helper"

RSpec.describe A3::Agent::HttpControlPlaneClient do
  let(:tmpdir) { Dir.mktmpdir }
  let(:job_store) { A3::Infra::JsonAgentJobStore.new(File.join(tmpdir, "agent-jobs.json")) }
  let(:artifact_store) { A3::Infra::FileAgentArtifactStore.new(File.join(tmpdir, "agent-artifacts")) }
  let(:handler) { A3::Infra::AgentHttpPullHandler.new(job_store: job_store, artifact_store: artifact_store, clock: -> { "2026-04-11T08:00:00Z" }) }
  let(:server) { A3::Infra::AgentHttpPullServer.new(handler: handler, port: 0) }
  let(:server_thread) { Thread.new { server.start } }

  after do
    server.shutdown
    server_thread.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  it "claims jobs, uploads artifacts, and submits results through HTTP" do
    job_store.enqueue(agent_job_request("job-1"))
    server_thread
    client = described_class.new(base_url: "http://127.0.0.1:#{server.bound_port}")

    request = client.claim_next(agent_name: "host-local")
    expect(request.job_id).to eq("job-1")

    content = "combined log\n"
    upload = A3::Domain::AgentArtifactUpload.new(
      artifact_id: "job-1-combined-log",
      role: "combined-log",
      digest: "sha256:#{Digest::SHA256.hexdigest(content)}",
      byte_size: content.bytesize,
      retention_class: :diagnostic
    )
    expect(client.upload_artifact(upload, content)).to eq(upload)
    expect(client.submit_result(agent_job_result("job-1", upload))).to eq(true)
    expect(job_store.fetch("job-1")).to have_attributes(state: :completed)
  end

  it "sends bearer auth when configured" do
    secured_handler = A3::Infra::AgentHttpPullHandler.new(
      job_store: job_store,
      artifact_store: artifact_store,
      auth_token: "secret-token"
    )
    secured_server = A3::Infra::AgentHttpPullServer.new(handler: secured_handler, port: 0)
    secured_thread = Thread.new { secured_server.start }
    job_store.enqueue(agent_job_request("job-1"))

    client = described_class.new(
      base_url: "http://127.0.0.1:#{secured_server.bound_port}",
      auth_token: "secret-token"
    )

    expect(client.claim_next(agent_name: "host-local").job_id).to eq("job-1")
  ensure
    secured_server&.shutdown
    secured_thread&.join(2)
  end

  it "redacts failed response bodies from raised errors" do
    secured_handler = A3::Infra::AgentHttpPullHandler.new(
      job_store: job_store,
      artifact_store: artifact_store,
      auth_token: "secret-token"
    )
    secured_server = A3::Infra::AgentHttpPullServer.new(handler: secured_handler, port: 0)
    secured_thread = Thread.new { secured_server.start }

    client = described_class.new(base_url: "http://127.0.0.1:#{secured_server.bound_port}")

    expect do
      client.claim_next(agent_name: "host-local")
    end.to raise_error(RuntimeError, /\Aclaim_next failed: HTTP 401\z/)
  ensure
    secured_server&.shutdown
    secured_thread&.join(2)
  end

  def agent_job_request(job_id)
    A3::Domain::AgentJobRequest.new(
      job_id: job_id,
      task_ref: "Sample#42",
      phase: :verification,
      runtime_profile: "host-local",
      source_descriptor: source_descriptor,
      working_dir: tmpdir,
      command: "ruby",
      args: ["-e", "puts :ok"],
      env: {},
      timeout_seconds: 60,
      artifact_rules: []
    )
  end

  def agent_job_result(job_id, upload)
    A3::Domain::AgentJobResult.new(
      job_id: job_id,
      status: :succeeded,
      exit_code: 0,
      started_at: "2026-04-11T08:00:00Z",
      finished_at: "2026-04-11T08:00:01Z",
      summary: "ok",
      log_uploads: [upload],
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
      runtime_profile: "host-local",
      workspace_id: "host-local-job-1",
      source_descriptor: source_descriptor,
      slot_descriptors: {}
    )
  end
end
