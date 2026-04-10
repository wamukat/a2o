# frozen_string_literal: true

require "digest"
require "spec_helper"

RSpec.describe A3::Agent::RunOnceWorker do
  let(:tmpdir) { Dir.mktmpdir }
  let(:working_dir) { File.join(tmpdir, "workspace") }
  let(:request) do
    A3::Domain::AgentJobRequest.new(
      job_id: "job-1",
      task_ref: "Portal#42",
      phase: :verification,
      runtime_profile: "host-local",
      source_descriptor: A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: "Portal#42", ref: "abc123"),
      working_dir: working_dir,
      command: "task",
      args: ["test:all"],
      env: {},
      timeout_seconds: 60,
      artifact_rules: [
        {
          "role" => "junit",
          "glob" => "target/*.xml",
          "retention_class" => "evidence",
          "media_type" => "application/xml"
        }
      ]
    )
  end
  let(:client) { FakeControlPlaneClient.new(request) }
  let(:executor) do
    Class.new do
      def call(_request)
        A3::Agent::LocalCommandExecutor::Result.new(
          status: :succeeded,
          exit_code: 0,
          combined_log: "all checks passed\n"
        )
      end
    end.new
  end

  before do
    FileUtils.mkdir_p(File.join(working_dir, "target"))
    File.write(File.join(working_dir, "target", "surefire.xml"), "<testsuite />\n")
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "claims one job, uploads logs and artifacts, and submits an upload-backed result" do
    result = described_class.new(
      agent_name: "host-local",
      control_plane_client: client,
      command_executor: executor,
      clock: fixed_clock
    ).call

    expect(result.status).to eq(:succeeded)
    expect(client.uploaded.map(&:role)).to eq(["combined-log", "junit"])
    expect(client.result.log_uploads.fetch(0).artifact_id).to eq("job-1-combined-log")
    expect(client.result.artifact_uploads.fetch(0).role).to eq("junit")
    expect(client.result.workspace_descriptor.workspace_kind).to eq(:runtime_workspace)
  end

  it "returns idle when no job is available" do
    idle_client = FakeControlPlaneClient.new(nil)

    result = described_class.new(
      agent_name: "host-local",
      control_plane_client: idle_client,
      command_executor: executor,
      clock: fixed_clock
    ).call

    expect(result).to eq(:idle)
  end

  def fixed_clock
    -> { Time.utc(2026, 4, 11, 9, 0, 0) }
  end

  class FakeControlPlaneClient
    attr_reader :uploaded, :result

    def initialize(request)
      @request = request
      @uploaded = []
    end

    def claim_next(agent_name:)
      @agent_name = agent_name
      @request
    end

    def upload_artifact(upload, content)
      expected_digest = "sha256:#{Digest::SHA256.hexdigest(content)}"
      raise "digest mismatch" unless upload.digest == expected_digest

      @uploaded << upload
      upload
    end

    def submit_result(result)
      @result = result
      true
    end
  end
end
