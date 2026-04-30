# frozen_string_literal: true

require "spec_helper"

RSpec.describe A3::Infra::AgentDecompositionCommandRunner do
  Result = Struct.new(:succeeded?, :exit_code, :worker_protocol_result, keyword_init: true)
  Record = Struct.new(:state, :result, keyword_init: true)

  class DecompositionControlPlane
    attr_reader :requests

    def initialize(result:)
      @result = result
      @requests = []
    end

    def enqueue(request)
      @requests << request
      Record.new(state: :queued, result: nil)
    end

    def fetch(_job_id)
      Record.new(state: :completed, result: @result)
    end
  end

  it "enqueues a host-agent decomposition job and returns stdout stderr status tuple" do
    result = Result.new(
      succeeded?: true,
      exit_code: 0,
      worker_protocol_result: {
        "diagnostics" => {
          "stdout" => "command stdout\n",
          "stderr" => "command stderr\n"
        }
      }
    )
    control_plane = DecompositionControlPlane.new(result: result)
    runner = described_class.new(
      control_plane_client: control_plane,
      runtime_profile: "host-local",
      task_ref: "A2O#411",
      stage: :propose,
      job_id_generator: -> { "job-411" }
    )

    stdout, stderr, status = runner.call(["/host/project/author.sh", "--json"], chdir: "/host/work", env: { "A2O_DECOMPOSITION_AUTHOR_REQUEST_PATH" => "/host/request.json" })

    expect(stdout).to eq("command stdout\n")
    expect(stderr).to eq("command stderr\n")
    expect(status).to be_success
    request = control_plane.requests.fetch(0)
    expect(request.phase).to eq(:verification)
    expect(request.run_ref).to eq("decomposition:propose:A2O#411:job-411")
    expect(request.working_dir).to eq("/host/work")
    expect(request.args).to eq(["-lc", "/host/project/author.sh --json"])
    expect(request.worker_protocol_request).to include("command_intent" => "decomposition_propose")
    expect(request.workspace_request).to be_nil
  end
end
