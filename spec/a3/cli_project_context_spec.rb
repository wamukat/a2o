# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  it "prints project context including merge config" do
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
                  "skill" => "skills/implementation/base.md",
                  "workspace_hook" => "hooks/prepare-runtime.sh"
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
                  "target" => "merge_to_live",
                  "policy" => "no_ff",
                  "target_ref" => "refs/heads/live"
                }
              }
            }
          }
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-project-context",
          manifest_path,
          "--preset-dir", File.join(dir, "presets"),
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
