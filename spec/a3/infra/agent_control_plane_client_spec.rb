# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Infra::AgentControlPlaneClient do
  let(:tmpdir) { Dir.mktmpdir }
  let(:job_store) { A3::Infra::JsonAgentJobStore.new(File.join(tmpdir, "agent-jobs.json")) }
  let(:handler) { A3::Infra::AgentHttpPullHandler.new(job_store: job_store, clock: -> { "2026-04-11T08:00:00Z" }) }
  let(:server) { A3::Infra::AgentHttpPullServer.new(handler: handler, port: 0) }
  let(:server_thread) { Thread.new { server.start } }

  after do
    server.shutdown
    server_thread.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  it "enqueues and fetches job records through HTTP" do
    server_thread
    client = described_class.new(base_url: "http://127.0.0.1:#{server.bound_port}")

    enqueued = client.enqueue(agent_job_request("job-1"))
    fetched = client.fetch("job-1")

    expect(enqueued.job_id).to eq("job-1")
    expect(fetched).to eq(enqueued)
  end

  it "sends bearer auth when configured" do
    secured_handler = A3::Infra::AgentHttpPullHandler.new(
      job_store: job_store,
      auth_token: "secret-token"
    )
    secured_server = A3::Infra::AgentHttpPullServer.new(handler: secured_handler, port: 0)
    secured_thread = Thread.new { secured_server.start }

    client = described_class.new(
      base_url: "http://127.0.0.1:#{secured_server.bound_port}",
      auth_token: "secret-token"
    )

    expect(client.enqueue(agent_job_request("job-1")).job_id).to eq("job-1")
    expect(client.fetch("job-1").job_id).to eq("job-1")
  ensure
    secured_server&.shutdown
    secured_thread&.join(2)
  end

  it "redacts failed response bodies from raised errors" do
    secured_handler = A3::Infra::AgentHttpPullHandler.new(
      job_store: job_store,
      control_auth_token: "control-token"
    )
    secured_server = A3::Infra::AgentHttpPullServer.new(handler: secured_handler, port: 0)
    secured_thread = Thread.new { secured_server.start }

    client = described_class.new(base_url: "http://127.0.0.1:#{secured_server.bound_port}")

    expect do
      client.enqueue(agent_job_request("job-1"))
    end.to raise_error(RuntimeError, /\Aenqueue failed: HTTP 401\z/)
  ensure
    secured_server&.shutdown
    secured_thread&.join(2)
  end

  def agent_job_request(job_id)
    A3::Domain::AgentJobRequest.new(
      job_id: job_id,
      task_ref: "Sample#42",
      phase: :implementation,
      runtime_profile: "host-local",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Sample#42", ref: "abc123"),
      working_dir: tmpdir,
      command: "ruby",
      args: ["-e", "puts :ok"],
      env: {},
      timeout_seconds: 60,
      artifact_rules: []
    )
  end
end
