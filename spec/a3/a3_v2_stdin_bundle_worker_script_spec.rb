# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "tmpdir"
require_relative "../../../scripts/a3/a3_v2_stdin_bundle_worker"

RSpec.describe "a3_v2_stdin_bundle_worker.rb" do
  root_dir = Pathname(__dir__).join("..", "..", "..").expand_path
  worker_script = root_dir.join("scripts", "a3", "a3_v2_stdin_bundle_worker.rb")

  define_method(:base_request) do
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

  define_method(:write_fake_codex) do |temp_dir|
    fake = temp_dir.join("codex")
    fake.write(<<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      require "pathname"

      args = ARGV.dup
      argv_path = ENV["FAKE_CODEX_ARGV_PATH"]
      Pathname(argv_path).write(JSON.generate(args)) if argv_path
      output_path = Pathname(args[args.index("--output-last-message") + 1])
      _schema_path = Pathname(args[args.index("--output-schema") + 1])
      _bundle = STDIN.read
      payload =
        if ENV["FAKE_CODEX_MODE"] == "invalid"
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
            "changed_files" => { "repo_alpha" => ["src/main.rb"] }
          }
        end
      output_path.write(JSON.generate(payload))
      exit 0
    RUBY
    File.chmod(0o755, fake)
  end

  define_method(:run_ruby) do |ruby, env:|
    Open3.capture3(env, "ruby", "-e", ruby, chdir: root_dir.to_s)
  end

  it "writes success payload from codex output file" do
    Dir.mktmpdir("a3-v2-stdin-worker-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      write_fake_codex(temp_dir)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(base_request))

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{temp_dir}:#{ENV.fetch('PATH')}",
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s
        },
        "ruby",
        worker_script.to_s,
        chdir: root_dir.to_s
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("summary")).to eq("implemented")
      expect(payload.fetch("success")).to eq(true)
      expect(payload.fetch("changed_files")).to eq("repo_alpha" => ["src/main.rb"])
    end
  end

  it "rewrites invalid payload as schema failure" do
    Dir.mktmpdir("a3-v2-stdin-worker-invalid-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      write_fake_codex(temp_dir)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(base_request))

      stdout, stderr, status = Open3.capture3(
        {
          "PATH" => "#{temp_dir}:#{ENV.fetch('PATH')}",
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s,
          "FAKE_CODEX_MODE" => "invalid"
        },
        "ruby",
        worker_script.to_s,
        chdir: root_dir.to_s
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(false)
      expect(payload.fetch("summary")).to eq("worker result schema invalid")
      expect(payload.fetch("observed_state")).to eq("invalid_worker_result")
      expect(payload.fetch("diagnostics")).to have_key("validation_errors")
    end
  end

  it "tells implementation workers not to commit and to return changed_files" do
    request = base_request
    Dir.mktmpdir("a3-v2-stdin-worker-bundle-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      ruby = <<~RUBY
        require #{worker_script.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        print bundle_for(request)
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
      bundle = JSON.parse(stdout)
      instruction = bundle.fetch("instruction")
      expect(instruction).to include("request.task_packet")
      expect(instruction).to include("leave git staging/commit publication to the outer A3 runtime")
      expect(instruction).to include("include changed_files")
      expect(instruction).not_to include("commit it before returning success")
      expect(JSON.generate(bundle.fetch("request"))).to include("DB操作をJDBCからMyBatisへ変更する")
    end
  end

  it "uses the implementation phase executor profile" do
    request = base_request
    Dir.mktmpdir("a3-v2-stdin-worker-profile-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      ruby = <<~RUBY
        require #{worker_script.to_s.inspect}
        def load_executor_config
          {
            "kind" => "ai-cli",
            "launcher_bin" => "codex",
            "argv_prefix" => ["exec", "--json"],
            "prompt_transport" => "stdin-bundle",
            "default_profile" => {
              "model" => "gpt-5-codex",
              "reasoning_effort" => "medium",
              "extra_args" => ["--sandbox", "workspace-write"]
            },
            "phase_profiles" => {
              "implementation" => {
                "model" => "gpt-5.3-codex-spark",
                "reasoning_effort" => "high",
                "extra_args" => ["--config", "impl.toml"]
              }
            }
          }
        end
        request = load_json(#{request_path.to_s.inspect})
        command = codex_command(result_path: Pathname(#{result_path.to_s.inspect}), schema_path: Pathname("/tmp/schema.json"), request: request)
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
      command = JSON.parse(stdout)
      expect(command[command.index("--model") + 1]).to eq("gpt-5.3-codex-spark")
      expect(command[command.index("-c") + 1]).to eq('model_reasoning_effort="high"')
      expect(command).to include("--sandbox", "workspace-write", "--config", "impl.toml")
    end
  end

  it "uses the parent review phase executor profile" do
    request = {
      "task_ref" => "Portal#3140",
      "run_ref" => "run-parent-review-1",
      "phase" => "review",
      "phase_runtime" => { "task_kind" => "parent", "review_skill" => "skill.md" },
      "slot_paths" => { "repo_alpha" => "/tmp/workspace/repo-alpha", "repo_beta" => "/tmp/workspace/repo-beta" },
      "task_packet" => {
        "ref" => "Portal#3140",
        "title" => "親レビュー",
        "description" => "親レビュー本文",
        "status" => "In progress",
        "labels" => ["repo:both", "trigger:auto-parent"]
      }
    }
    Dir.mktmpdir("a3-v2-stdin-worker-parent-profile-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      ruby = <<~RUBY
        require #{worker_script.to_s.inspect}
        def load_executor_config
          {
            "kind" => "ai-cli",
            "launcher_bin" => "codex",
            "argv_prefix" => ["exec", "--json"],
            "prompt_transport" => "stdin-bundle",
            "default_profile" => {
              "model" => "gpt-5-codex",
              "reasoning_effort" => "medium",
              "extra_args" => []
            },
            "phase_profiles" => {
              "parent_review" => {
                "model" => "gpt-5-codex",
                "reasoning_effort" => "high",
                "extra_args" => ["--config", "parent-review.toml"]
              }
            }
          }
        end
        request = load_json(#{request_path.to_s.inspect})
        command = codex_command(result_path: Pathname(#{result_path.to_s.inspect}), schema_path: Pathname("/tmp/schema.json"), request: request)
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
      command = JSON.parse(stdout)
      expect(command[command.index("-c") + 1]).to eq('model_reasoning_effort="high"')
      expect(command).to include("--config", "parent-review.toml")
    end
  end

  it "fails closed on invalid executor config" do
    request = base_request
    Dir.mktmpdir("a3-v2-stdin-worker-invalid-executor-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      write_fake_codex(temp_dir)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      ruby = <<~RUBY
        require #{worker_script.to_s.inspect}
        def load_executor_config
          {
            "kind" => "ai-cli",
            "launcher_bin" => "codex",
            "argv_prefix" => ["exec", "--json"],
            "prompt_transport" => "stdin-bundle",
            "default_profile" => {
              "model" => "gpt-5-codex",
              "reasoning_effort" => "medium",
              "extra_args" => []
            },
            "phase_profiles" => {
              "verification" => {
                "model" => "gpt-5.3-codex-spark",
                "reasoning_effort" => "high",
                "extra_args" => []
              }
            }
          }
        end
        exit(main)
      RUBY

      stdout, stderr, status = run_ruby(
        ruby,
        env: {
          "PATH" => "#{temp_dir}:#{ENV.fetch('PATH')}",
          "A3_WORKER_REQUEST_PATH" => request_path.to_s,
          "A3_WORKER_RESULT_PATH" => result_path.to_s,
          "A3_WORKSPACE_ROOT" => workspace_root.to_s
        }
      )

      expect(status.success?).to eq(true), "#{stdout}\n#{stderr}"
      payload = JSON.parse(result_path.read)
      expect(payload.fetch("success")).to eq(false)
      expect(payload.fetch("summary")).to eq("stdin worker executor config invalid")
      expect(payload.fetch("observed_state")).to eq("invalid_executor_config")
      expect(payload.fetch("diagnostics").fetch("error")).to include("unknown phases")
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
    Dir.mktmpdir("a3-v2-stdin-worker-parent-review-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      ruby = <<~RUBY
        require #{worker_script.to_s.inspect}
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

  it "still requires changed_files in the implementation schema" do
    request = base_request
    Dir.mktmpdir("a3-v2-stdin-worker-implementation-schema-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      ruby = <<~RUBY
        require #{worker_script.to_s.inspect}
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
      expect(schema.fetch("required")).to include("changed_files")
      expect(schema.fetch("properties").fetch("review_disposition").fetch("type")).to eq("object")
    end
  end

  it "rejects non-completed review evidence in the implementation schema" do
    request = base_request
    Dir.mktmpdir("a3-v2-stdin-worker-implementation-evidence-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      payload = {
        "task_ref" => request.fetch("task_ref"),
        "run_ref" => request.fetch("run_ref"),
        "phase" => "implementation",
        "success" => true,
        "summary" => "implemented",
        "failing_command" => nil,
        "observed_state" => nil,
        "rework_required" => false,
        "changed_files" => { "repo_alpha" => ["src/main.rb"] },
        "review_disposition" => {
          "kind" => "blocked",
          "repo_scope" => "repo_alpha",
          "summary" => "No findings",
          "description" => "invalid",
          "finding_key" => "invalid"
        }
      }

      ruby = <<~RUBY
        require #{worker_script.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        payload = JSON.parse(#{JSON.generate(payload).inspect})
        print JSON.generate(validate_payload(payload, request: request))
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
      errors = JSON.parse(stdout)
      expect(errors).to include("review_disposition.kind must be completed for implementation evidence")
    end
  end

  it "includes a blocked review disposition in parent review failures" do
    request = {
      "task_ref" => "Portal#3140",
      "run_ref" => "run-parent-review-1",
      "phase" => "review",
      "phase_runtime" => { "task_kind" => "parent", "review_skill" => "skill.md" },
      "slot_paths" => { "repo_alpha" => "/tmp/workspace/repo-alpha", "repo_beta" => "/tmp/workspace/repo-beta" }
    }
    Dir.mktmpdir("a3-v2-stdin-worker-parent-review-failure-") do |temp_dir_text|
      temp_dir = Pathname(temp_dir_text)
      request_path = temp_dir.join("request.json")
      result_path = temp_dir.join("result.json")
      workspace_root = temp_dir.join("workspace")
      workspace_root.mkpath
      request_path.write(JSON.generate(request))

      ruby = <<~RUBY
        require #{worker_script.to_s.inspect}
        request = load_json(#{request_path.to_s.inspect})
        print JSON.generate(failure(request, summary: "launcher failed", command: ["codex", "exec"], observed_state: "exit 1"))
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
      payload = JSON.parse(stdout)
      expect(payload.fetch("review_disposition").fetch("kind")).to eq("blocked")
      expect(payload.fetch("review_disposition").fetch("repo_scope")).to eq("unresolved")
    end
  end
end
