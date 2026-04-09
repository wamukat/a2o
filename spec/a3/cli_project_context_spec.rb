# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  it "prints project context including merge config" do
    Dir.mktmpdir do |dir|
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(
        File.join(preset_dir, "base.yml"),
        YAML.dump(
          {
            "schema_version" => "1",
            "implementation_skill" => "skills/implementation/base.md",
            "review_skill" => "skills/review/default.md",
            "verification_commands" => ["commands/verify-all"],
            "remediation_commands" => ["commands/apply-remediation"],
            "workspace_hook" => "hooks/prepare-runtime.sh"
          }
        )
      )
      manifest_path = File.join(dir, "manifest.yml")
      File.write(
        manifest_path,
        YAML.dump(
          {
            "presets" => ["base"],
            "core" => {
              "merge_target" => "merge_to_live",
              "merge_policy" => "no_ff",
              "merge_target_ref" => "refs/heads/live"
            }
          }
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-project-context",
          manifest_path,
          "--preset-dir", preset_dir,
          "--task-kind", "child",
          "--repo-scope", "repo_beta",
          "--phase", "review"
        ],
        out: out
      )

      expect(out.string).to include("merge_target=merge_to_live")
      expect(out.string).to include("merge_policy=no_ff")
      expect(out.string).to include("implementation_skill=skills/implementation/base.md")
    end
  end
end
