# frozen_string_literal: true

require "tmpdir"
require_relative "../../../scripts/a3/ensure_a3_v2_direct_repo_sources"

RSpec.describe EnsureA3V2DirectRepoSources do
  it "reports ready when each scratch parent repo and leaf worktree exists" do
    Dir.mktmpdir("a3-v2-ensure-direct-repo-sources-") do |temp_dir|
      target_root = Pathname(temp_dir)
      BootstrapA3V2DirectRepoSources::SOURCES.each_key do |repo_name|
        FileUtils.mkdir_p(BootstrapA3V2DirectRepoSources.scratch_parent_repo_path(target_root, repo_name))
        leaf = BootstrapA3V2DirectRepoSources.scratch_leaf_path(target_root, repo_name)
        FileUtils.mkdir_p(leaf.join(".git"))
      end

      expect(described_class.target_ready?(target_root)).to eq(true)
    end
  end

  it "reports not ready when any required leaf worktree is missing" do
    Dir.mktmpdir("a3-v2-ensure-direct-repo-sources-missing-") do |temp_dir|
      target_root = Pathname(temp_dir)
      FileUtils.mkdir_p(BootstrapA3V2DirectRepoSources.scratch_parent_repo_path(target_root, "member-portal-starters"))

      expect(described_class.target_ready?(target_root)).to eq(false)
    end
  end

  it "skips destructive bootstrap when the target is already ready" do
    Dir.mktmpdir("a3-v2-ensure-direct-repo-sources-skip-") do |temp_dir|
      target_root = Pathname(temp_dir)
      BootstrapA3V2DirectRepoSources::SOURCES.each_key do |repo_name|
        FileUtils.mkdir_p(BootstrapA3V2DirectRepoSources.scratch_parent_repo_path(target_root, repo_name))
        leaf = BootstrapA3V2DirectRepoSources.scratch_leaf_path(target_root, repo_name)
        FileUtils.mkdir_p(leaf.join(".git"))
      end

      allow(BootstrapA3V2DirectRepoSources).to receive(:main)

      expect do
        described_class.main(["--target-root", target_root.to_s])
      end.to output("#{target_root}\n").to_stdout
      expect(BootstrapA3V2DirectRepoSources).not_to have_received(:main)
    end
  end

  it "delegates to the destructive bootstrap when scratch repo sources are absent" do
    Dir.mktmpdir("a3-v2-ensure-direct-repo-sources-bootstrap-") do |temp_dir|
      target_root = Pathname(temp_dir)

      allow(BootstrapA3V2DirectRepoSources).to receive(:main).and_return(0)

      expect do
        described_class.main(["--target-root", target_root.to_s])
      end.to output("#{target_root}\n").to_stdout
      expect(BootstrapA3V2DirectRepoSources).to have_received(:main).with(["--target-root", target_root.to_s])
    end
  end
end
