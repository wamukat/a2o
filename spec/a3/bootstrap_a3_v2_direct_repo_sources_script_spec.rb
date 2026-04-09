# frozen_string_literal: true

require "tmpdir"
require_relative "../../../scripts/a3/bootstrap_a3_v2_direct_repo_sources"

RSpec.describe BootstrapA3V2DirectRepoSources do
  it "derives hidden parent repo and leaf paths under the target root" do
    target_root = Pathname("/tmp/portal-direct-repo-sources")

    expect(described_class.scratch_parent_repo_path(target_root, "member-portal-ui-app").to_s)
      .to eq("/tmp/portal-direct-repo-sources/.repo-store/member-portal-ui-app.git")
    expect(described_class.scratch_leaf_path(target_root, "member-portal-ui-app").to_s)
      .to eq("/tmp/portal-direct-repo-sources/member-portal-ui-app")
  end

  it "raises when repo identity does not match" do
    Dir.mktmpdir("a3-v2-bootstrap-identity-") do |temp_dir|
      source = Pathname(temp_dir).join("source")
      FileUtils.mkdir_p(source)

      allow(described_class).to receive(:run_capture).and_return(
        { stdout: "#{temp_dir}/other\n", stderr: "", status: instance_double(Process::Status, success?: true) }
      )

      expect do
        described_class.assert_repo_identity(source, source, role: "source")
      end.to raise_error(RuntimeError, /repo identity mismatch/)
    end
  end

  it "raises when destination shares the same repository" do
    Dir.mktmpdir("a3-v2-bootstrap-common-dir-") do |temp_dir|
      source = Pathname(temp_dir).join("source")
      other = Pathname(temp_dir).join("other")
      FileUtils.mkdir_p([source, other])

      allow(described_class).to receive(:run_capture).and_return(
        { stdout: "#{temp_dir}/git/source\n", stderr: "", status: instance_double(Process::Status, success?: true) },
        { stdout: "#{temp_dir}/git/source\n", stderr: "", status: instance_double(Process::Status, success?: true) }
      )

      expect do
        described_class.assert_distinct_repository(source, other, role: "destination")
      end.to raise_error(RuntimeError, /repository must be distinct/)
    end
  end

  it "raises when destination is not owned by the scratch parent repo" do
    Dir.mktmpdir("a3-v2-bootstrap-owner-") do |temp_dir|
      destination = Pathname(temp_dir).join("destination")
      parent = Pathname(temp_dir).join("parent.git")
      FileUtils.mkdir_p([destination, parent])

      allow(described_class).to receive(:git_common_dir).with(destination).and_return(Pathname("#{temp_dir}/leaf-common"))
      allow(described_class).to receive(:git_common_dir_for_git_dir).with(parent).and_return(Pathname("#{temp_dir}/parent-common"))

      expect do
        described_class.assert_same_repository_owner(destination, parent, role: "destination")
      end.to raise_error(RuntimeError, /repository owner mismatch/)
    end
  end

  it "uses worktree remove for registered destinations" do
    Dir.mktmpdir("a3-v2-bootstrap-worktree-remove-") do |temp_dir|
      source = Pathname(temp_dir).join("parent.git")
      destination = Pathname(temp_dir).join("destination")
      FileUtils.mkdir_p([source, destination])

      allow(described_class).to receive(:registered_worktree).and_return(true)
      allow(described_class).to receive(:run)

      described_class.remove_destination(source, destination)

      expect(described_class).to have_received(:run).with("git", "--git-dir", source.to_s, "worktree", "remove", "--force", destination.to_s).ordered
      expect(described_class).to have_received(:run).with("git", "--git-dir", source.to_s, "worktree", "prune").ordered
    end
  end

  it "refreshes the scratch parent repo by mirror clone" do
    Dir.mktmpdir("a3-v2-bootstrap-parent-") do |temp_dir|
      source = Pathname(temp_dir).join("source")
      parent = Pathname(temp_dir).join(".repo-store", "member-portal-ui-app.git")
      FileUtils.mkdir_p(source)
      run_calls = []

      allow(described_class).to receive(:assert_repo_identity)
      allow(described_class).to receive(:git_common_dir).with(source).and_return(Pathname("#{temp_dir}/source-common"))
      allow(described_class).to receive(:git_common_dir_for_git_dir).with(parent).and_return(Pathname("#{temp_dir}/parent-common"))
      allow(described_class).to receive(:run) do |*args, **kwargs|
        run_calls << [args, kwargs]
      end

      described_class.refresh_scratch_parent_repo(source, parent)

      expect(run_calls).to eq(
        [
          [["git", "clone", "--mirror", "--no-local", source.to_s, parent.to_s], {}]
        ]
      )
    end
  end

  it "refreshes the existing scratch parent repo by fetch" do
    Dir.mktmpdir("a3-v2-bootstrap-parent-rerun-") do |temp_dir|
      source = Pathname(temp_dir).join("source")
      parent = Pathname(temp_dir).join(".repo-store", "member-portal-ui-app.git")
      FileUtils.mkdir_p([source, parent])
      run_calls = []

      allow(described_class).to receive(:assert_repo_identity)
      allow(described_class).to receive(:git_common_dir).with(source).and_return(Pathname("#{temp_dir}/source-common"))
      allow(described_class).to receive(:git_common_dir_for_git_dir).with(parent).and_return(Pathname("#{temp_dir}/parent-common"))
      allow(described_class).to receive(:run) do |*args, **kwargs|
        run_calls << [args, kwargs]
      end

      described_class.refresh_scratch_parent_repo(source, parent)

      expect(run_calls).to eq(
        [
          [["git", "--git-dir", parent.to_s, "remote", "set-url", "origin", source.to_s], {}],
          [["git", "--git-dir", parent.to_s, "fetch", "--prune", "origin", "+refs/*:refs/*"], {}]
        ]
      )
    end
  end

  it "refreshes detached scratch leaf worktree and live branch" do
    Dir.mktmpdir("a3-v2-bootstrap-worktree-add-") do |temp_dir|
      source = Pathname(temp_dir).join("source")
      parent = Pathname(temp_dir).join(".repo-store", "member-portal-ui-app.git")
      destination = Pathname(temp_dir).join("destination")
      FileUtils.mkdir_p([source, parent.dirname])
      run_calls = []

      allow(described_class).to receive(:remove_destination)
      allow(described_class).to receive(:run) do |*args, **kwargs|
        run_calls << [args, kwargs]
      end
      allow(described_class).to receive(:current_head).with(parent).and_return("abc123")
      allow(described_class).to receive(:assert_distinct_repository)
      allow(described_class).to receive(:assert_same_repository_owner)

      described_class.refresh_leaf_worktree(source, parent, destination)

      expect(described_class).to have_received(:remove_destination).with(parent, destination)
      expect(described_class).to have_received(:current_head).with(parent)
      expect(described_class).to have_received(:assert_distinct_repository).with(destination, source, role: "destination")
      expect(described_class).to have_received(:assert_same_repository_owner).with(destination, parent, role: "destination")
      expect(run_calls).to eq(
        [
          [["git", "--git-dir", parent.to_s, "worktree", "add", "--force", "--detach", destination.to_s, "abc123"], {}],
          [["git", "branch", "--force", "live", "HEAD"], { cwd: destination }]
        ]
      )
    end
  end
end
