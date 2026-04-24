# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../../lib/a3/operator/stdin_bundle_worker"

RSpec.describe "worker:stdin-bundle" do
  STDIN_WORKER_SPEC_ROOT_DIR = Pathname(__dir__).join("..", "..").expand_path
  STDIN_WORKER_ENTRYPOINT = STDIN_WORKER_SPEC_ROOT_DIR.join("bin", "a3")
  STDIN_WORKER_LIB_DIR = STDIN_WORKER_SPEC_ROOT_DIR.join("lib")
  STDIN_WORKER_LIB = STDIN_WORKER_LIB_DIR.join("a3", "operator", "stdin_bundle_worker.rb")

  it "keeps legacy worker env as private compatibility fallback" do
    original_public = ENV.delete("A2O_WORKER_REQUEST_PATH")
    original_legacy = ENV["A3_WORKER_REQUEST_PATH"]
    ENV["A3_WORKER_REQUEST_PATH"] = "/tmp/legacy-request.json"

    expect(env_compat("A2O_WORKER_REQUEST_PATH", "A3_WORKER_REQUEST_PATH")).to eq("/tmp/legacy-request.json")
  ensure
    ENV["A2O_WORKER_REQUEST_PATH"] = original_public if original_public
    if original_legacy
      ENV["A3_WORKER_REQUEST_PATH"] = original_legacy
    else
      ENV.delete("A3_WORKER_REQUEST_PATH")
    end
  end

  it "sanitizes internal diagnostic names before writing worker failure payloads" do
    sanitized = sanitize_diagnostic_value(
      "A3_WORKER_REQUEST_PATH /tmp/a3-engine/lib/a3/bootstrap.rb /usr/local/bin/a3 .a2o/workspace.json"
    )

    expect(sanitized).to include("A2O_WORKER_REQUEST_PATH")
    expect(sanitized).to include("<runtime-preset-dir>/lib/a2o-internal")
    expect(sanitized).to include("<engine-entrypoint>")
    expect(sanitized).to include("<agent-metadata>")
    expect(sanitized).not_to include("A3_WORKER_REQUEST_PATH")
    expect(sanitized).not_to include("/tmp/a3-engine")
    expect(sanitized).not_to include("/usr/local/bin/a3")
    expect(sanitized).not_to include(".a3")
  end

  it "sanitizes failing_command in worker failure payloads" do
    payload = failure(
      base_request,
      summary: "failed",
      command: ["A3_WORKER_REQUEST_PATH=/tmp/request.json", "/usr/local/bin/a3"],
      observed_state: "executor_failed",
      diagnostics: {}
    )

    expect(payload.fetch("failing_command")).to include("A2O_WORKER_REQUEST_PATH")
    expect(payload.fetch("failing_command")).to include("<engine-entrypoint>")
    expect(payload.fetch("failing_command")).not_to include("A3_WORKER_REQUEST_PATH")
    expect(payload.fetch("failing_command")).not_to include("/usr/local/bin/a3")
  end

  it "classifies verification failures ahead of dirty-word diagnostics in worker helper output" do
    payload = failure(
      base_request.merge("phase" => "verification"),
      summary: "verification failed because lint found an untracked generated file",
      command: ["commands/verify-all"],
      observed_state: "exit 1 due to untracked generated file",
      diagnostics: {}
    )

    expect(payload.fetch("diagnostics").fetch("error_category")).to eq("verification_failed")
    expect(payload.fetch("diagnostics").fetch("remediation")).to include("verification")
  end

  it "keeps publish workspace dirtiness classified as workspace_dirty in worker helper output" do
    payload = failure(
      base_request.merge("phase" => "verification"),
      summary: "slot app has changes but is not an edit target: [README.md]",
      command: ["publish_workspace_changes"],
      observed_state: "slot app has changes but is not an edit target: [README.md]",
      diagnostics: {}
    )

    expect(payload.fetch("diagnostics").fetch("error_category")).to eq("workspace_dirty")
    expect(payload.fetch("diagnostics").fetch("remediation")).to include("commit")
  end

  def base_request
    {
      "task_ref" => "Sample#3112",
      "run_ref" => "run-1",
      "phase" => "implementation",
      "phase_runtime" => { "implementation_skill" => "skill.md" },
      "slot_paths" => { "repo_alpha" => "/tmp/workspace/repo-alpha" },
      "task_packet" => {
        "ref" => "Sample#3112",
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
            "task_ref" => "Sample#3112",
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

  def run_worker_process(env)
    Open3.capture3(
      env,
      "ruby",
      "-I",
      STDIN_WORKER_LIB_DIR.to_s,
      STDIN_WORKER_ENTRYPOINT.to_s,
      "worker:stdin-bundle",
      chdir: STDIN_WORKER_SPEC_ROOT_DIR.to_s
    )
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

      stdout, stderr, status = run_worker_process(
        {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s,
          "A2O_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("summary")).to eq("implemented")
      expect(payload.fetch("success")).to eq(true)
      expect(payload.fetch("changed_files")).to eq("repo_alpha" => ["src/main.rb"])
    end
  end

  it "writes AI raw log when configured" do
    Dir.mktmpdir("a3-stdin-worker-ai-raw-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      fake_worker = temp_dir.join("fake-worker")
      fake_worker.write(<<~RUBY)
        #!/usr/bin/env ruby
        require "json"
        require "pathname"
        warn "assistant is thinking"
        puts "assistant streamed token"
        output_path = Pathname(ARGV[ARGV.index("--result") + 1])
        output_path.write(JSON.generate({
          "task_ref" => "Sample#3112",
          "run_ref" => "run-1",
          "phase" => "implementation",
          "success" => true,
          "summary" => "implemented",
          "failing_command" => nil,
          "observed_state" => nil,
          "rework_required" => false,
          "changed_files" => { "repo_alpha" => [] },
          "review_disposition" => {
            "kind" => "completed",
            "repo_scope" => "repo_alpha",
            "summary" => "self review clean",
            "description" => "No findings.",
            "finding_key" => "self-review-clean"
          }
        }))
      RUBY
      File.chmod(0o755, fake_worker)

      launcher_config = temp_dir.join("launcher.json")
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      ai_raw_root = temp_dir.join("ai-raw-logs")
      workspace_root.mkpath
      request_path.write(JSON.generate(base_request))
      write_launcher_config(
        launcher_config,
        command: [fake_worker.to_s, "--result", "{{result_path}}", "--schema", "{{schema_path}}"]
      )

      stdout, stderr, status = run_worker_process(
        {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s,
          "A2O_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s,
          "A2O_AGENT_AI_RAW_LOG_ROOT" => ai_raw_root.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      body = ai_raw_root.join("Sample-3112", "implementation.log").read
      expect(body).to include("assistant streamed token")
      expect(body).to include("assistant is thinking")
    end
  end

  it "does not fall back to root launcher.json when launcher config env is missing" do
    Dir.mktmpdir("a3-stdin-worker-missing-launcher-env-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(base_request))
      temp_dir.join("launcher.json").write(JSON.generate("executor" => {}))

      stdout, stderr, status = run_worker_process(
        {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_ROOT_DIR" => temp_dir.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(false)
      expect(payload.fetch("summary")).to eq("stdin worker executor config invalid")
      expect(payload.fetch("observed_state")).to eq("invalid_executor_config")
      expect(payload.fetch("diagnostics").fetch("error")).to include("A2O_WORKER_LAUNCHER_CONFIG_PATH is required")
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

      stdout, stderr, status = run_worker_process(
        {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s,
          "A2O_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s,
          "FAKE_WORKER_MODE" => "invalid"
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(false)
      expect(payload.fetch("summary")).to eq("worker result schema invalid")
      expect(payload.fetch("observed_state")).to eq("invalid_worker_result")
      expect(payload.fetch("diagnostics")).to have_key("validation_errors")
    end
  end

  it "does not require review_disposition for implementation failures" do
    payload = {
      "task_ref" => "Sample#3112",
      "run_ref" => "run-1",
      "phase" => "implementation",
      "success" => false,
      "summary" => "implementation failed",
      "failing_command" => "bundle exec rspec",
      "observed_state" => "spec failed",
      "rework_required" => false
    }

    expect(validate_payload(payload, request: base_request)).to eq([])
  end

  it "accepts structured skill feedback in worker helper validation" do
    payload = {
      "task_ref" => "Sample#3112",
      "run_ref" => "run-1",
      "phase" => "review",
      "success" => true,
      "summary" => "review clean",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "skill_feedback" => {
        "category" => "missing_context",
        "summary" => "Add setup guidance to the project skill.",
        "proposal" => {
          "target" => "project_skill",
          "suggested_patch" => "Check setup before verification."
        },
        "confidence" => "medium"
      }
    }
    request = base_request.merge("phase" => "review")

    expect(validate_payload(payload, request: request)).to eq([])
  end

  it "rejects malformed skill feedback in worker helper validation" do
    payload = {
      "task_ref" => "Sample#3112",
      "run_ref" => "run-1",
      "phase" => "review",
      "success" => false,
      "summary" => "review failed",
      "failing_command" => "review_worker",
      "observed_state" => "invalid feedback",
      "rework_required" => false,
      "skill_feedback" => {
        "summary" => "missing category",
        "proposal" => {}
      }
    }
    request = base_request.merge("phase" => "review")

    expect(validate_payload(payload, request: request)).to include(
      "skill_feedback[0].category must be a string",
      "skill_feedback[0].proposal.target must be a string"
    )
  end

  it "requires review_disposition for implementation success" do
    payload = {
      "task_ref" => "Sample#3112",
      "run_ref" => "run-1",
      "phase" => "implementation",
      "success" => true,
      "summary" => "implemented",
      "failing_command" => nil,
      "observed_state" => nil,
      "rework_required" => false,
      "changed_files" => { "repo_alpha" => ["src/main.rb"] }
    }

    expect(validate_payload(payload, request: base_request)).to include(
      "review_disposition must be present for implementation success"
    )
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
        command: ["runner", "--result", "{{result_path}}", "--schema", "{{schema_path}}", "--cwd", "{{workspace_root}}", "--root", "{{a2o_root_dir}}"]
      )

      ruby = <<~RUBY
        ENV["A2O_WORKER_LAUNCHER_CONFIG_PATH"] = #{launcher_config.to_s.inspect}
        require #{STDIN_WORKER_LIB.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        command = executor_command(result_path: Pathname(#{result_path.to_s.inspect}), schema_path: Pathname("/tmp/schema.json"), request: request)
        print JSON.generate(command)
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s,
          "A2O_ROOT_DIR" => temp_dir.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      expect(JSON.parse(stdout)).to eq(["runner", "--result", result_path.to_s, "--schema", "/tmp/schema.json", "--cwd", workspace_root.to_s, "--root", temp_dir.to_s])
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
        ENV["A2O_WORKER_LAUNCHER_CONFIG_PATH"] = #{launcher_config.to_s.inspect}
        require #{STDIN_WORKER_LIB.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        command = executor_command(result_path: Pathname(#{result_path.to_s.inspect}), schema_path: Pathname("/tmp/schema.json"), request: request)
        print JSON.generate(command)
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      expect(JSON.parse(stdout)).to eq(["implementation-runner", "/tmp/schema.json"])
    end
  end

  it "normalizes review disposition repo scope only through injected aliases" do
    request = base_request
    payload = {
      "task_ref" => "Sample#3112",
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
        ENV["A2O_WORKER_LAUNCHER_CONFIG_PATH"] = #{launcher_config.to_s.inspect}
        require #{STDIN_WORKER_LIB.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        payload = load_json(#{payload_path.to_s.inspect})
        print JSON.generate(validate_payload(payload, request: request))
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => temp_dir.join("result.json").to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      expect(JSON.parse(stdout)).to eq([])
    end
  end

  it "does not hardcode project-specific repo label aliases in the engine worker" do
    request = base_request
    payload = {
      "task_ref" => "Sample#3112",
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
        ENV["A2O_WORKER_LAUNCHER_CONFIG_PATH"] = #{launcher_config.to_s.inspect}
        require #{STDIN_WORKER_LIB.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        payload = load_json(#{payload_path.to_s.inspect})
        print JSON.generate(validate_payload(payload, request: request))
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => temp_dir.join("result.json").to_s
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

      stdout, stderr, status = run_worker_process(
        {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s,
          "A2O_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s
        }
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

      stdout, stderr, status = run_worker_process(
        {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s,
          "A2O_WORKER_LAUNCHER_CONFIG_PATH" => launcher_config.to_s
        }
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
      "task_ref" => "Sample#3140",
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
        require #{STDIN_WORKER_LIB.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        print JSON.generate(response_schema(request))
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "A2O_WORKER_REQUEST_PATH" => request_path.to_s,
          "A2O_WORKER_RESULT_PATH" => result_path.to_s,
          "A2O_WORKSPACE_ROOT" => workspace_root.to_s
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
