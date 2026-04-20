# frozen_string_literal: true

require "json"
require "tmpdir"

RSpec.describe A3::CLI do
  describe "prepare-workspace" do
    let(:tmpdir) { Dir.mktmpdir("a3-v2-cli-workspace") }
    let(:storage_dir) { File.join(tmpdir, "storage") }
    let(:repo_sources) { create_repo_sources(tmpdir) }
    let(:out) { StringIO.new }

    before do
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(storage_dir, "tasks.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: %i[repo_alpha repo_beta]
        )
      )
    end

    after do
      FileUtils.remove_entry(tmpdir)
    end

    it "materializes fixed repo slots for the requested phase" do
      described_class.start(
        [
          "prepare-workspace",
          "--storage-dir", storage_dir,
          *repo_source_args(repo_sources),
          "--source-type", "detached_commit",
          "--source-ref", "abc123",
          "--bootstrap-marker", "workspace-hook:v1",
          "A3-v2#3025",
          "review"
        ],
        out: out
      )

      expect(out.string).to include("prepared workspace")

      workspace_root = Pathname(storage_dir).join("workspaces", "A3-v2-3025", "runtime_workspace")
      expect(workspace_root.join("repo_alpha")).to exist
      expect(workspace_root.join("repo_beta")).to exist

      metadata = JSON.parse(workspace_root.join(".a3", "workspace.json").read)
      expect(metadata.fetch("workspace_kind")).to eq("runtime_workspace")
      slot_metadata = JSON.parse(workspace_root.join(".a2o", "slots", "repo_alpha", "slot.json").read)
      expect(slot_metadata.fetch("bootstrap_marker")).to eq("workspace-hook:v1")
      expect(workspace_root.join("repo_alpha", ".a3")).not_to exist
      expect(workspace_root.join("repo_alpha", "README.md").read).to eq("repo_alpha source\n")
      expect(workspace_root.join("repo_beta", "README.md").read).to eq("repo_beta source\n")
    end
  end
end
