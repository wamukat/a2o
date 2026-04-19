# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  it "shows and updates scheduler state through sqlite backend" do
    Dir.mktmpdir do |dir|
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      write_project_yaml(
        File.join(dir, "project.yaml"),
        merge_target: "merge_to_parent",
        merge_target_ref: "refs/heads/live"
      )
      out = StringIO.new
      described_class.start(
        ["pause-scheduler", "--storage-backend", "sqlite", "--storage-dir", dir],
        out: out
      )
      described_class.start(
        ["show-scheduler-state", "--storage-backend", "sqlite", "--storage-dir", dir],
        out: out
      )
      described_class.start(
        ["resume-scheduler", "--storage-backend", "sqlite", "--storage-dir", dir],
        out: out
      )
      described_class.start(
        [
          "execute-until-idle",
          File.join(dir, "project.yaml"),
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--preset-dir", preset_dir,
          "--max-steps", "1"
        ],
        out: out
      )
      described_class.start(
        ["show-scheduler-state", "--storage-backend", "sqlite", "--storage-dir", dir],
        out: out
      )

      expect(out.string).to include("scheduler paused=true")
      expect(out.string).to include("scheduler paused=false")
      expect(out.string).to include("executed 0 task(s); idle=true stop_reason=idle quarantined=0")
      expect(out.string).to include("scheduler paused=false stop_reason=idle executed_count=0")
    end
  end
end
