# frozen_string_literal: true

require "json"
require "set"
require "tmpdir"
require_relative "../../../scripts/a3/a3_v2_direct_canary_worker"

RSpec.describe A3V2DirectCanaryWorker do
  def base_request(phase: "implementation")
    {
      "task_ref" => "Portal#3157",
      "run_ref" => "run-1",
      "phase" => phase,
      "skill" => "skills/implementation/base.md",
      "slot_paths" => {
        "repo_beta" => "/tmp/workspace/repo-beta"
      }
    }
  end

  it "returns noop diagnostics when diff is disabled" do
    payload = described_class.maybe_apply_local_live_diff(base_request, env: {})

    expect(payload).to eq(
      "worker_mode" => "direct_canary_noop",
      "changed_files" => {}
    )
  end

  it "reports changed marker file when diff is enabled" do
    Dir.mktmpdir("a3-v2-direct-canary-worker-") do |temp_dir|
      repo_root = Pathname(temp_dir).join("repo-beta")
      repo_root.mkpath
      request = base_request.merge("slot_paths" => { "repo_beta" => repo_root.to_s })

      payload = described_class.maybe_apply_local_live_diff(
        request,
        env: { "A3_V2_DIRECT_CANARY_DIFF_TASK_REFS" => "Portal#3157" }
      )

      expect(payload.fetch("changed_files")).to eq(
        "repo_beta" => [".a3-canary/local-live-merge-verification.md"]
      )
      expect(payload.fetch("diff_applied")).to eq(true)
      expect(repo_root.join(".a3-canary", "local-live-merge-verification.md").read)
        .to include("Portal#3157 (repo_beta): implementation diff generated")
    end
  end

  it "writes worker result payload from request and env" do
    Dir.mktmpdir("a3-v2-direct-canary-worker-main-") do |temp_dir|
      root = Pathname(temp_dir)
      request_path = root.join("request.json")
      result_path = root.join("result.json")
      repo_root = root.join("repo-beta")
      repo_root.mkpath
      request = base_request.merge("slot_paths" => { "repo_beta" => repo_root.to_s })
      request_path.write(JSON.generate(request))

      rc = described_class.main(
        env: {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_V2_DIRECT_CANARY_DIFF_TASK_REFS" => "Portal#3157"
        }
      )

      expect(rc).to eq(0)
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(true)
      expect(payload.fetch("changed_files")).to eq(
        "repo_beta" => [".a3-canary/local-live-merge-verification.md"]
      )
      expect(payload.fetch("diagnostics").fetch("worker_mode")).to eq("direct_canary_diff_write")
    end
  end

  it "runs as a standalone script process" do
    Dir.mktmpdir("a3-v2-direct-canary-worker-cli-") do |temp_dir|
      root = Pathname(temp_dir)
      request_path = root.join("request.json")
      result_path = root.join("result.json")
      repo_root = root.join("repo-beta")
      repo_root.mkpath
      request = base_request.merge("slot_paths" => { "repo_beta" => repo_root.to_s })
      request_path.write(JSON.generate(request))

      completed = system(
        {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_V2_DIRECT_CANARY_DIFF_TASK_REFS" => "Portal#3157"
        },
        "ruby",
        described_class.method(:main).source_location.first
      )

      expect(completed).to eq(true)
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(true)
      expect(payload.fetch("phase")).to eq("implementation")
    end
  end
end
