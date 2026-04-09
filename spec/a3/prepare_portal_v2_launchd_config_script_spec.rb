# frozen_string_literal: true

require "tmpdir"
require_relative "../../../scripts/a3/prepare_portal_v2_launchd_config"

RSpec.describe PreparePortalV2LaunchdConfig do
  it "writes env file and plist" do
    Dir.mktmpdir("a3-v2-launchd-config-") do |dir|
      root = Pathname(dir)
      plist_path = root.join(".work", "a3-v2", "scheduler", "portal", "scheduler.plist")
      env_file = root.join(".work", "a3-v2", "env", "portal-launchd.env")
      stdout_log = root.join(".work", "a3-v2", "scheduler", "portal", "stdout.log")
      stderr_log = root.join(".work", "a3-v2", "scheduler", "portal", "stderr.log")

      result = described_class.prepare_portal_v2_launchd_config(
        env: {
          "PATH" => "/usr/local/bin:/usr/bin:/bin",
          "JAVA_HOME" => "/opt/jdks/temurin-25",
          "A3_V2_ALLOW_LIVE_WRITE" => "1"
        },
        root_dir: root,
        plist_path: plist_path,
        env_file: env_file,
        stdout_log: stdout_log,
        stderr_log: stderr_log
      )

      expect(result.fetch("plist_path")).to eq(plist_path.to_s)
      expect(env_file).to exist
      env_payload = env_file.read
      expect(env_payload).to include("export JAVA_HOME=")
      expect(env_payload).to include("export A3_V2_ALLOW_LIVE_WRITE=1")

      plist = plist_path.read
      expect(plist).to include("<key>Label</key>")
      expect(plist).to include(described_class::JOB_LABEL)
      expect(plist).to include("<key>WorkingDirectory</key>")
      expect(plist).to include(root.to_s)
      expect(plist).to include("<integer>60</integer>")
      expect(plist).to include(env_file.to_s)
      expect(plist).to include(root.join("scripts", "a3", "portal_v2_scheduler_launcher.rb").to_s)
    end
  end
end
