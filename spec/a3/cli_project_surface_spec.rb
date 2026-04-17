# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  it "prints resolved project surface from manifest and presets" do
    Dir.mktmpdir do |dir|
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(
        File.join(preset_dir, "base.yml"),
        YAML.dump(
          {
            "schema_version" => "1",
            "implementation_skill" => "skills/implementation/base.md",
            "review_skill" => {
              "default" => "skills/review/default.md",
              "variants" => {
                "task_kind" => {
                  "parent" => {
                    "repo_scope" => {
                      "repo_alpha" => {
                        "phase" => {
                          "review" => "skills/review/repo-alpha-parent.md"
                        }
                      }
                    }
                  }
                }
              }
            },
            "verification_commands" => ["commands/verify-all"],
            "remediation_commands" => ["commands/apply-remediation"],
            "workspace_hook" => "hooks/prepare-runtime.sh"
          }
        )
      )
      manifest_path = File.join(dir, "project.yaml")
      File.write(
        manifest_path,
        YAML.dump(
          {
            "schema_version" => 1,
            "runtime" => {
              "presets" => ["base"]
            }
          }
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-project-surface",
          manifest_path,
          "--preset-dir", preset_dir,
          "--task-kind", "parent",
          "--repo-scope", "repo_alpha",
          "--phase", "review"
        ],
        out: out
      )

      expect(out.string).to include("implementation_skill=skills/implementation/base.md")
      expect(out.string).to include("review_skill=skills/review/repo-alpha-parent.md")
      expect(out.string).to include("verification_commands=commands/verify-all")
    end
  end

  it "does not print review_skill for child implementation surface" do
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
            "verification_commands" => ["commands/verify-all"]
          }
        )
      )
      manifest_path = File.join(dir, "project.yaml")
      File.write(manifest_path, YAML.dump({ "schema_version" => 1, "runtime" => { "presets" => ["base"] } }))

      out = StringIO.new

      described_class.start(
        [
          "show-project-surface",
          manifest_path,
          "--preset-dir", preset_dir,
          "--task-kind", "child",
          "--repo-scope", "repo_alpha",
          "--phase", "implementation"
        ],
        out: out
      )

      expect(out.string).to include("implementation_skill=skills/implementation/base.md")
      expect(out.string).not_to include("review_skill=")
    end
  end
end
