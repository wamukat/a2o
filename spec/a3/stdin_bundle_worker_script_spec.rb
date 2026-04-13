# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../../../scripts/a3/a3_stdin_bundle_worker"

RSpec.describe "a3_stdin_bundle_worker.rb" do
  STDIN_WORKER_SPEC_ROOT_DIR = Pathname(__dir__).join("..", "..", "..").expand_path
  STDIN_WORKER_SCRIPT = STDIN_WORKER_SPEC_ROOT_DIR.join("scripts", "a3", "a3_stdin_bundle_worker.rb")

  def base_request
    {
      "task_ref" => "Portal#3112",
      "run_ref" => "run-1",
      "phase" => "implementation",
      "phase_runtime" => { "implementation_skill" => "skill.md" },
      "slot_paths" => { "repo_alpha" => "/tmp/workspace/repo-alpha" },
      "task_packet" => {
        "ref" => "Portal#3112",
        "title" => "DB操作をJDBCからMyBatisへ変更する",
        "description" => "JDBC 実装を MyBatis に置き換える。",
        "status" => "In progress",
        "labels" => ["repo:starters", "trigger:auto-implement"]
      }
    }
  end

  def write_launcher_config(path, command:, phase_profiles: {}, review_disposition_repo_scope_aliases: {}, review_disposition_repo_scopes: nil)
    executor = {
      "kind" => "command",
      "prompt_transport" => "stdin-bundle",
      "result" => { "mode" => "file" },
      "schema" => { "mode" => "file" },
      "default_profile" => {
        "command" => command,
        "env" => {}
      },
      "phase_profiles" => phase_profiles,
      "review_disposition_repo_scope_aliases" => review_disposition_repo_scope_aliases
    }
    executor["review_disposition_repo_scopes"] = review_disposition_repo_scopes if review_disposition_repo_scopes
    path.write(
      JSON.generate(
        "executor" => executor
      )
    )
  end

  def write_fake_worker(temp_dir)
    fake = temp_dir.join("fake-worker")
    fake.write(<<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      require "pathname"

      args = ARGV.dup
      output_path = Pathname(args[args.index("--result") + 1])
      _schema_path = Pathname(args[args.index("--schema") + 1])
      _bundle = STDIN.read
      payload =
        if ENV["FAKE_WORKER_MODE"] == "invalid"
          { "success" => true }
        else
          {
            "task_ref" => "Portal#3112",
            "run_ref" => "run-1",
            "phase" => "implementation",
            "success" => true,
            "summary" => "implemented",
            "failing_command" => nil,
            "observed_state" => nil,
            "rework_required" => false,
            "changed_files" => { "repo_alpha" => ["src/main.rb"] },
            "review_disposition" => {
              "kind" => "completed",
              "repo_scope" => "repo_alpha",
              "summary" => "self review clean",
              "description" => "No findings.",
              "finding_key" => "self-review-clean"
            }
          }
        end
      output_path.write(JSON.generate(payload))
      exit 0
    RUBY
    File.chmod(0o755, fake)
    fake
  end

  def run_ruby(ruby, env:)
    Open3.capture3(env, "ruby", "-e", ruby, chdir: STDIN_WORKER_SPEC_ROOT_DIR.to_s)
  end

  it "writes success payload from configured command output file" do
    Dir.mktmpdir("a3-stdin-worker-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      fake_worker = write_fake_worker(temp_dir)
      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(base_request))
      write_launcher_config(
        launcher_config,
        command: [fake_worker.to_s, "--result", "{{result_path}}", "--schema", "{{schema_path}}"]
      )

      stdout, stderr, status = Open3.capture3(
        {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s,
          "A3_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s
        },
        "ruby",
        STDIN_WORKER_SCRIPT.to_s,
        chdir: STDIN_WORKER_SPEC_ROOT_DIR.to_s
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("summary")).to eq("implemented")
      expect(payload.fetch("success")).to eq(true)
      expect(payload.fetch("changed_files")).to eq("repo_alpha" => ["src/main.rb"])
    end
  end

  it "rewrites invalid payload as schema failure" do
    Dir.mktmpdir("a3-stdin-worker-invalid-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      fake_worker = write_fake_worker(temp_dir)
      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(base_request))
      write_launcher_config(
        launcher_config,
        command: [fake_worker.to_s, "--result", "{{result_path}}", "--schema", "{{schema_path}}"]
      )

      stdout, stderr, status = Open3.capture3(
        {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s,
          "A3_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s,
          "FAKE_WORKER_MODE" => "invalid"
        },
        "ruby",
        STDIN_WORKER_SCRIPT.to_s,
        chdir: STDIN_WORKER_SPEC_ROOT_DIR.to_s
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(false)
      expect(payload.fetch("summary")).to eq("worker result schema invalid")
      expect(payload.fetch("observed_state")).to eq("invalid_worker_result")
      expect(payload.fetch("diagnostics")).to have_key("validation_errors")
    end
  end

  it "expands executor command placeholders from injected launcher config" do
    request = base_request
    Dir.mktmpdir("a3-stdin-worker-profile-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))
      write_launcher_config(
        launcher_config,
        command: ["runner", "--result", "{{result_path}}", "--schema", "{{schema_path}}", "--cwd", "{{workspace_root}}"]
      )

      ruby = <<~RUBY
        ENV["A3_WORKER_LAUNCHER_CONFIG_PATH"] = #{launcher_config.to_s.inspect}
        require #{STDIN_WORKER_SCRIPT.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        command = executor_command(result_path: Pathname(#{result_path.to_s.inspect}), schema_path: Pathname("/tmp/schema.json"), request: request)
        print JSON.generate(command)
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      expect(JSON.parse(stdout)).to eq(["runner", "--result", result_path.to_s, "--schema", "/tmp/schema.json", "--cwd", workspace_root.to_s])
    end
  end

  it "uses phase-specific executor profiles from injected launcher config" do
    request = base_request
    Dir.mktmpdir("a3-stdin-worker-phase-profile-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))
      write_launcher_config(
        launcher_config,
        command: ["default-runner", "{{result_path}}"],
        phase_profiles: {
          "implementation" => {
            "command" => ["implementation-runner", "{{schema_path}}"]
          }
        }
      )

      ruby = <<~RUBY
        ENV["A3_WORKER_LAUNCHER_CONFIG_PATH"] = #{launcher_config.to_s.inspect}
        require #{STDIN_WORKER_SCRIPT.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        command = executor_command(result_path: Pathname(#{result_path.to_s.inspect}), schema_path: Pathname("/tmp/schema.json"), request: request)
        print JSON.generate(command)
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      expect(JSON.parse(stdout)).to eq(["implementation-runner", "/tmp/schema.json"])
    end
  end

  it "normalizes review disposition repo scope only through injected aliases" do
    request = base_request
    payload = {
      "task_ref" => "Portal#3112",
      "run_ref" => "run-1",
      "phase" => "implementation",
      "success" => true,
      "summary" => "implemented",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => { "repo_alpha" => ["src/main.rb"] },
      "review_disposition" => {
        "kind" => "completed",
        "repo_scope" => "repo:starters",
        "summary" => "self review clean",
        "description" => "No findings.",
        "finding_key" => "self-review-clean"
      }
    }
    Dir.mktmpdir("a3-stdin-worker-alias-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      payload_path = temp_dir.join("payload.json")
      request_path.write(JSON.generate(request))
      payload_path.write(JSON.generate(payload))
      write_launcher_config(
        launcher_config,
        command: ["runner", "{{result_path}}"],
        review_disposition_repo_scope_aliases: { "repo:starters" => "repo_alpha" }
      )

      ruby = <<~RUBY
        ENV["A3_WORKER_LAUNCHER_CONFIG_PATH"] = #{launcher_config.to_s.inspect}
        require #{STDIN_WORKER_SCRIPT.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        payload = load_json(#{payload_path.to_s.inspect})
        print JSON.generate(validate_payload(payload, request: request))
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => temp_dir.join("result.json").to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      expect(JSON.parse(stdout)).to eq([])
    end
  end

  it "does not hardcode Portal repo label aliases in the engine worker" do
    request = base_request
    payload = {
      "task_ref" => "Portal#3112",
      "run_ref" => "run-1",
      "phase" => "implementation",
      "success" => true,
      "summary" => "implemented",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => { "repo_alpha" => ["src/main.rb"] },
      "review_disposition" => {
        "kind" => "completed",
        "repo_scope" => "repo:starters",
        "summary" => "self review clean",
        "description" => "No findings.",
        "finding_key" => "self-review-clean"
      }
    }
    Dir.mktmpdir("a3-stdin-worker-no-alias-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      payload_path = temp_dir.join("payload.json")
      request_path.write(JSON.generate(request))
      payload_path.write(JSON.generate(payload))
      write_launcher_config(launcher_config, command: ["runner", "{{result_path}}"])

      ruby = <<~RUBY
        ENV["A3_WORKER_LAUNCHER_CONFIG_PATH"] = #{launcher_config.to_s.inspect}
        require #{STDIN_WORKER_SCRIPT.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        payload = load_json(#{payload_path.to_s.inspect})
        print JSON.generate(validate_payload(payload, request: request))
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => temp_dir.join("result.json").to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      expect(JSON.parse(stdout)).to include("review_disposition.repo_scope must be one of repo_alpha")
    end
  end

  it "reports invalid review disposition alias config as structured failure" do
    Dir.mktmpdir("a3-stdin-worker-invalid-alias-config-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      fake_worker = write_fake_worker(temp_dir)
      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(base_request))
      write_launcher_config(
        launcher_config,
        command: [fake_worker.to_s, "--result", "{{result_path}}", "--schema", "{{schema_path}}"],
        review_disposition_repo_scope_aliases: { "repo:starters" => 123 }
      )

      stdout, stderr, status = Open3.capture3(
        {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s,
          "A3_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s
        },
        "ruby",
        STDIN_WORKER_SCRIPT.to_s,
        chdir: STDIN_WORKER_SPEC_ROOT_DIR.to_s
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(false)
      expect(payload.fetch("summary")).to eq("stdin worker executor config invalid")
      expect(payload.fetch("observed_state")).to eq("invalid_executor_config")
      expect(payload.fetch("diagnostics").fetch("error")).to include("review_disposition_repo_scope_aliases")
    end
  end

  it "reports invalid configured repo scopes as structured failure before launching the executor" do
    Dir.mktmpdir("a3-stdin-worker-invalid-scope-config-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      fake_worker = write_fake_worker(temp_dir)
      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(base_request))
      write_launcher_config(
        launcher_config,
        command: [fake_worker.to_s, "--result", "{{result_path}}", "--schema", "{{schema_path}}"],
        review_disposition_repo_scopes: [123]
      )

      stdout, stderr, status = Open3.capture3(
        {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s,
          "A3_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s
        },
        "ruby",
        STDIN_WORKER_SCRIPT.to_s,
        chdir: STDIN_WORKER_SPEC_ROOT_DIR.to_s
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(false)
      expect(payload.fetch("summary")).to eq("stdin worker executor config invalid")
      expect(payload.fetch("observed_state")).to eq("invalid_executor_config")
      expect(payload.fetch("diagnostics").fetch("error")).to include("review_disposition_repo_scopes")
    end
  end

  it "requires review_disposition in the parent review schema" do
    request = {
      "task_ref" => "Portal#3140",
      "run_ref" => "run-parent-review-1",
      "phase" => "review",
      "phase_runtime" => { "task_kind" => "parent", "review_skill" => "skill.md" },
      "slot_paths" => { "repo_alpha" => "/tmp/workspace/repo-alpha", "repo_beta" => "/tmp/workspace/repo-beta" }
    }
    Dir.mktmpdir("a3-stdin-worker-parent-review-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      ruby = <<~RUBY
        require #{STDIN_WORKER_SCRIPT.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        print JSON.generate(response_schema(request))
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      schema = JSON.parse(stdout)
      expect(schema.fetch("properties").fetch("review_disposition").fetch("type")).to eq("object")
      expect(schema.fetch("required")).to include("review_disposition")
      expect(schema.fetch("properties")).not_to have_key("changed_files")
    end
  end
end
