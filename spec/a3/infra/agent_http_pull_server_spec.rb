# frozen_string_literal: true

require "json"
require "net/http"
require "digest"
require "spec_helper"

RSpec.describe A3::Infra::AgentHttpPullServer do
  let(:tmpdir) { Dir.mktmpdir }
  let(:store) { A3::Infra::JsonAgentJobStore.new(File.join(tmpdir, "agent-jobs.json")) }
  let(:artifact_store) { A3::Infra::FileAgentArtifactStore.new(File.join(tmpdir, "agent-artifacts")) }
  let(:handler) { A3::Infra::AgentHttpPullHandler.new(job_store: store, artifact_store: artifact_store, clock: -> { "2026-04-11T08:00:00Z" }) }
  let(:server) { described_class.new(handler: handler, port: 0) }
  let(:server_thread) { Thread.new { server.start } }

  after do
    server.shutdown
    server_thread.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  it "serves the agent pull API over HTTP" do
    server_thread
    base_uri = URI("http://127.0.0.1:#{server.bound_port}")

    enqueue_response = post_json(
      base_uri + "/v1/agent/jobs",
      agent_job_request("job-1").request_form
    )
    expect(enqueue_response.code).to eq("201")

    claim_response = Net::HTTP.get_response(base_uri + "/v1/agent/jobs/next?agent=host-local-agent")
    expect(claim_response.code).to eq("200")
    expect(JSON.parse(claim_response.body).fetch("job").fetch("job_id")).to eq("job-1")

    result_response = post_json(
      base_uri + "/v1/agent/jobs/job-1/result",
      agent_job_result("job-1").result_form
    )
    expect(result_response.code).to eq("200")
    expect(store.fetch("job-1")).to have_attributes(state: :completed)
  end

  it "serves artifact upload requests over HTTP" do
    server_thread
    base_uri = URI("http://127.0.0.1:#{server.bound_port}")
    content = "verification log\n"
    digest = "sha256:#{Digest::SHA256.hexdigest(content)}"

    response = put_content(
      base_uri + "/v1/agent/artifacts/art-log-1?role=combined-log&digest=#{digest}&byte_size=#{content.bytesize}&retention_class=diagnostic&media_type=text/plain",
      content
    )

    expect(response.code).to eq("201")
    expect(artifact_store.fetch_metadata("art-log-1").digest).to eq(digest)
    expect(artifact_store.read("art-log-1")).to eq(content)
  end

  def post_json(uri, payload)
    request = Net::HTTP::Post.new(uri)
    request["content-type"] = "application/json"
    request.body = JSON.generate(payload)
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
  end

  def put_content(uri, content)
    request = Net::HTTP::Put.new(uri)
    request["content-type"] = "text/plain"
    request.body = content
    Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
  end

  def agent_job_request(job_id)
    A3::Domain::AgentJobRequest.new(
      job_id: job_id,
      task_ref: "Portal#42",
      phase: :verification,
      runtime_profile: "host-local-agent",
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
      runtime_profile: "host-local-agent",
      workspace_id: "workspace-portal-42",
      source_descriptor: source_descriptor,
      slot_descriptors: {}
    )
  end
end
