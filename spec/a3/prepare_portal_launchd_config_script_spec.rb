# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "../../../scripts/a3/prepare_portal_launchd_config"

RSpec.describe PreparePortalLaunchdConfig do
  it "injects local env file without mutating tracked base config" do
    Dir.mktmpdir("a3-portal-launchd-config-") do |dir|
      root = Pathname(dir)
      base_config = root.join("scripts", "a3", "config", "portal", "launcher.json")
      base_config.dirname.mkpath
      base_config.write(
        JSON.pretty_generate(
          {
            "executor" => { "kind" => "ai-cli", "implementation" => "openai-codex" },
            "scheduler" => {
              "backend" => "launchd",
              "job_name" => "dev.a3-engine.portal.watch",
              "interval_seconds" => 60,
              "command_argv" => ["/bin/sh", "-lc", "echo 'Legacy Portal A3 scheduler is disabled. Use task a3:portal-v2:scheduler:*.' >&2; exit 1"],
              "working_directory" => "../../../../"
            },
            "runtime_env" => { "required_bins" => ["python3"] },
            "shell" => { "env_files" => [], "env_overrides" => {} },
            "kanban" => {
              "backend" => "subprocess-cli",
              "command_argv" => ["task", "kanban:api", "--"],
              "working_directory" => "../../../../"
            }
          }
        )
      )
      output_config = root.join(".work", "a3", "config", "portal-launchd.json")
      env_file = root.join(".work", "a3", "env", "portal-launchd.env")

      payload = described_class.prepare_portal_launchd_config(
        base_config: base_config,
        output_config: output_config,
        env_file: env_file,
        root_dir: root,
        env: {
          "JAVA_HOME" => "/opt/jdks/temurin-25",
          "SDKMAN_DIR" => "/Users/test/.sdkman",
          "PATH" => "/Users/test/.sdkman/candidates/java/current/bin:/usr/local/bin:/usr/bin:/bin"
        }
      )

      expect(payload.fetch("shell").fetch("env_files")).to eq([env_file.to_s])
      expect(payload.fetch("shell").fetch("env_overrides").fetch("JAVA_HOME")).to eq("/opt/jdks/temurin-25")
      expect(payload.fetch("shell").fetch("env_overrides").fetch("SDKMAN_DIR")).to eq("/Users/test/.sdkman")
      expect(payload.fetch("shell").fetch("env_overrides").fetch("PATH")).to start_with("/opt/jdks/temurin-25/bin:")
      expect(payload.fetch("scheduler").fetch("working_directory")).to eq(root.to_s)

      written = JSON.parse(output_config.read)
      expect(written.fetch("shell").fetch("env_files")).to eq([env_file.to_s])
      expect(written.fetch("shell").fetch("env_overrides").fetch("JAVA_HOME")).to eq("/opt/jdks/temurin-25")
      expect(written.fetch("scheduler").fetch("working_directory")).to eq(root.to_s)

      original = JSON.parse(base_config.read)
      expect(original.fetch("shell").fetch("env_files")).to eq([])
    end
  end
end
