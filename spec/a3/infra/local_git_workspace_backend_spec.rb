# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::LocalGitWorkspaceBackend do
  subject(:backend) { described_class.new }

  it "recognizes linked worktree paths as git repositories" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      linked_worktree = Pathname(File.join(dir, "linked-worktree"))

      create_git_repo_source(dir, name: "repo")
      system("git", "-C", source_root.to_s, "worktree", "add", "--force", "--detach", linked_worktree.to_s, "HEAD")

      expect(backend.git_repo?(linked_worktree)).to be(true)
    ensure
      system("git", "-C", source_root.to_s, "worktree", "remove", "--force", linked_worktree.to_s)
      system("git", "-C", source_root.to_s, "worktree", "prune")
    end
  end

  it "bootstraps a missing ticket branch from HEAD when requested" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      destination = Pathname(File.join(dir, "worktree"))

      create_git_repo_source(dir, name: "repo")

      backend.materialize(
        source_root: source_root,
        destination: destination,
        ref: "refs/heads/a2o/work/Sample-3046",
        create_branch_if_missing: true
      )

      expect(destination).to exist
      branch_ref = `git -C #{source_root} rev-parse refs/heads/a2o/work/Sample-3046`.strip
      head_ref = `git -C #{source_root} rev-parse HEAD`.strip
      expect(branch_ref).to eq(head_ref)
    end
  end

  it "registers source and materialized worktree paths as git safe directories" do
    Dir.mktmpdir do |dir|
      home = File.join(dir, "home")
      FileUtils.mkdir_p(home)
      with_env("HOME" => home) do
        source_root = Pathname(File.join(dir, "repo"))
        destination = Pathname(File.join(dir, "worktree"))

        create_git_repo_source(dir, name: "repo")
        backend.materialize(
          source_root: source_root,
          destination: destination,
          ref: "HEAD"
        )

        safe_directories = `git config --global --get-all safe.directory`.lines.map(&:strip)
        expect(safe_directories).to include(source_root.realpath.to_s)
        expect(safe_directories).to include(destination.realpath.to_s)
      end
    end
  end

  it "resets an existing ticket branch to HEAD when requested" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      destination = Pathname(File.join(dir, "worktree"))

      create_git_repo_source(dir, name: "repo")
      File.write(source_root.join("NEXT.md"), "fresh\n")
      system("git", "-C", source_root.to_s, "add", "NEXT.md", exception: true)
      system("git", "-C", source_root.to_s, "commit", "-m", "advance head", exception: true)

      branch_name = "refs/heads/a2o/work/Sample-3046"
      previous_head = `git -C #{source_root} rev-parse HEAD~1`.strip
      system("git", "-C", source_root.to_s, "branch", "--force", branch_name.delete_prefix("refs/heads/"), previous_head, exception: true)

      backend.materialize(
        source_root: source_root,
        destination: destination,
        ref: branch_name,
        create_branch_if_missing: true,
        reset_branch_to: "HEAD"
      )

      branch_ref = `git -C #{source_root} rev-parse #{branch_name}`.strip
      head_ref = `git -C #{source_root} rev-parse HEAD`.strip
      expect(branch_ref).to eq(head_ref)
      expect(`git -C #{destination} rev-parse HEAD`.strip).to eq(head_ref)
    end
  end

  it "archives the previous ticket branch head before resetting it" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      destination = Pathname(File.join(dir, "worktree"))

      create_git_repo_source(dir, name: "repo")
      previous_head = `git -C #{source_root} rev-parse HEAD`.strip
      File.write(source_root.join("NEXT.md"), "fresh\n")
      system("git", "-C", source_root.to_s, "add", "NEXT.md", exception: true)
      system("git", "-C", source_root.to_s, "commit", "-m", "advance head", exception: true)

      branch_name = "refs/heads/a2o/work/Sample-3046"
      system("git", "-C", source_root.to_s, "branch", "--force", branch_name.delete_prefix("refs/heads/"), previous_head, exception: true)

      backend.materialize(
        source_root: source_root,
        destination: destination,
        ref: branch_name,
        create_branch_if_missing: true,
        reset_branch_to: "HEAD"
      )

      archive_ref = "refs/heads/a2o/archive/work/Sample-3046/#{previous_head[0, 12]}"
      expect(`git -C #{source_root} rev-parse #{archive_ref}`.strip).to eq(previous_head)
    end
  end

  it "falls back to removing an unregistered destination directory" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      destination = Pathname(File.join(dir, "stale-workspace"))

      create_git_repo_source(dir, name: "repo")
      FileUtils.mkdir_p(destination)
      File.write(destination.join("README.md"), "stale\n")

      expect { backend.remove(source_root: source_root, destination: destination) }.not_to raise_error
      expect(destination).not_to exist
    end
  end

  it "treats untracked destination files as not ready" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      destination = Pathname(File.join(dir, "worktree"))

      head_sha = create_git_repo_source(dir, name: "repo")
      backend.materialize(source_root: source_root, destination: destination, ref: "HEAD")
      destination.join("stale.java").write("untracked\n")

      expect(
        backend.ready?(source_root: source_root, destination: destination, ref: head_sha)
      ).to be(false)
    end
  end

  it "removes a registered stale worktree before materializing again" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo"))
      destination = Pathname(File.join(dir, "worktree"))

      head_sha = create_git_repo_source(dir, name: "repo")
      backend.materialize(source_root: source_root, destination: destination, ref: "HEAD")
      destination.join("stale.java").write("untracked\n")

      backend.materialize(source_root: source_root, destination: destination, ref: "HEAD")

      expect(destination.join("stale.java")).not_to exist
      expect(`git -C #{destination} rev-parse HEAD`.strip).to eq(head_sha)
    end
  end

  it "returns false when destination belongs to a different git repository" do
    Dir.mktmpdir do |dir|
      source_root = Pathname(File.join(dir, "repo-alpha"))
      destination = Pathname(File.join(dir, "repo-beta"))

      head_sha = create_git_repo_source(dir, name: "repo-alpha")
      create_git_repo_source(dir, name: "repo-beta")

      expect(
        backend.ready?(source_root: source_root, destination: destination, ref: head_sha)
      ).to be(false)
    end
  end
end
