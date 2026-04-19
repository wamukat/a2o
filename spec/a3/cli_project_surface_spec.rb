# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  it "prints resolved project surface from manifest and presets" do
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
                }
              }
            }
          }
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-project-surface",
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
      expect(out.string).to include("verification_commands=commands/verify-all")
    end
  end

  it "does not print review_skill for child implementation surface" do
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
                }
              }
            }
          }
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-project-surface",
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

  it "prints resolved verification command variants" do
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
                  "commands" => {
                    "default" => ["commands/verify-all"],
                    "variants" => {
                      "task_kind" => {
                        "parent" => {
                          "default" => ["commands/verify-parent"]
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-project-surface",
          manifest_path,
          "--preset-dir", File.join(dir, "presets"),
          "--task-kind", "parent",
          "--repo-scope", "repo_alpha",
          "--phase", "verification"
        ],
        out: out
      )

      expect(out.string).to include("verification_commands=commands/verify-parent")
    end
  end
end
