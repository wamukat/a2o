# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::CLI do
  it "prints merge plan from stored run and project context" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
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
                  "target_ref" => "refs/heads/live"
                }
              }
            }
          }
        )
      )
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-merge-1",
          task_ref: "A3-v2#3025",
          phase: :merge,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :integration_record,
            ref: "refs/heads/a2o/work/3025",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "show-merge-plan",
          "A3-v2#3025",
          "run-merge-1",
          manifest_path,
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--preset-dir", preset_dir
        ],
        out: out
      )

      expect(out.string).to include("merge_source=refs/heads/a2o/work/3025")
      expect(out.string).to include("merge_target=refs/heads/a2o/parent/A3-v2-3022")
      expect(out.string).to include("merge_policy=ff_only")
      expect(out.string).to include("merge_slots=repo_alpha")
    end
  end
end
