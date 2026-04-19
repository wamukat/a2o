# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  it "prints resolved phase runtime config from project context" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      File.write(
        manifest_path,
        YAML.dump(
          {
            "schema_version" => 1,
            "runtime" => {
              "phases" => {
                "implementation" => {
                  "skill" => "skills/implementation/base.md"
                },
                "review" => {
                  "skill" => "skills/review/default.md"
                },
                "parent_review" => {
                  "skill" => "skills/review/repo-alpha-parent.md"
                },
                "verification" => {
                  "commands" => ["commands/verify-all"]
                },
                "remediation" => {
                  "commands" => ["commands/apply-remediation"]
                },
                "merge" => {
                  "target" => "merge_to_parent",
                  "policy" => "ff_only",
                  "target_ref" => "refs/heads/a2o/parent/A3-v2-3022"
                }
              }
            }
          }
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-phase-runtime-config",
          manifest_path,
          "--preset-dir", File.join(dir, "presets"),
          "--task-kind", "parent",
          "--repo-scope", "both",
          "--phase", "review"
        ],
        out: out
      )

      expect(out.string).to include("implementation_skill=skills/implementation/base.md")
      expect(out.string).to include("review_skill=skills/review/repo-alpha-parent.md")
      expect(out.string).to include("merge_target=merge_to_parent")
    end
  end

  it "does not print review_skill for child implementation runtime config" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      File.write(
        manifest_path,
        YAML.dump(
          {
            "schema_version" => 1,
            "runtime" => {
              "phases" => {
                "implementation" => {
                  "skill" => "skills/implementation/base.md"
                },
                "review" => {
                  "skill" => "skills/review/default.md"
                },
                "verification" => {
                  "commands" => ["commands/verify-all"]
                },
                "remediation" => {
                  "commands" => ["commands/apply-remediation"]
                },
                "merge" => {
                  "target" => "merge_to_parent",
                  "policy" => "ff_only",
                  "target_ref" => "refs/heads/a2o/parent/A3-v2-3022"
                }
              }
            }
          }
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-phase-runtime-config",
          manifest_path,
          "--preset-dir", File.join(dir, "presets"),
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
