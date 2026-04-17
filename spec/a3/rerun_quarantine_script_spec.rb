# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "a3/operator/rerun_quarantine"

RSpec.describe A3RerunQuarantine do
  def must_run(*args, cwd:)
    stdout, stderr, status = Open3.capture3(*args, chdir: cwd.to_s)
    raise "command failed: #{args.join(' ')}\nstdout=#{stdout}\nstderr=#{stderr}" unless status.success?

    stdout
  end

  def init_repo(path)
    FileUtils.mkdir_p(path)
    must_run("git", "init", "-b", "feature/prototype", cwd: path)
    must_run("git", "config", "user.name", "A3 Test", cwd: path)
    must_run("git", "config", "user.email", "a3@example.com", cwd: path)
    File.write(path.join("README.md"), "seed\n")
    must_run("git", "add", "README.md", cwd: path)
    must_run("git", "commit", "-m", "seed", cwd: path)
  end

  it "moves default rerun paths outside the issue workspace" do
    Dir.mktmpdir("a3-rerun-quarantine-") do |dir|
      root = Pathname(dir)
      issue_workspace = root.join(".work", "a3", "issues", "sample", "sample-2700")
      repo = issue_workspace.join("sample-storefront")
      FileUtils.mkdir_p(issue_workspace.join(".work"))
      FileUtils.mkdir_p(issue_workspace.join(".support"))
      init_repo(repo)
      FileUtils.mkdir_p(repo.join("target"))
      FileUtils.mkdir_p(repo.join(".work"))

      result = described_class.quarantine_rerun_artifacts(
        root_dir: root,
        project: "sample",
        task_ref: "Sample#2700",
        now: Time.utc(2026, 3, 28, 1, 2, 3)
      )

      quarantine_root = Pathname(result.fetch("quarantine_root"))
      expect(issue_workspace.join(".work")).not_to exist
      expect(issue_workspace.join(".support")).not_to exist
      expect(repo.join("target")).not_to exist
      expect(repo.join(".work")).not_to exist
      expect(quarantine_root.join(".work")).to exist
      expect(quarantine_root.join(".support")).to exist
      expect(quarantine_root.join("sample-storefront", "target")).to exist
      expect(quarantine_root.join("sample-storefront", ".work")).to exist
      expect(quarantine_root.to_s).not_to include(issue_workspace.to_s)
    end
  end

  it "moves broken top-level support bridges" do
    Dir.mktmpdir("a3-rerun-quarantine-") do |dir|
      root = Pathname(dir)
      issue_workspace = root.join(".work", "a3", "issues", "sample", "sample-2700")
      FileUtils.mkdir_p(issue_workspace)
      broken_bridge = issue_workspace.join("sample-catalog-service")
      File.symlink(".support/sample-storefront/sample-catalog-service", broken_bridge)

      result = described_class.quarantine_rerun_artifacts(
        root_dir: root,
        project: "sample",
        task_ref: "Sample#2700",
        now: Time.utc(2026, 3, 28, 1, 2, 3)
      )

      quarantine_root = Pathname(result.fetch("quarantine_root"))
      expect(broken_bridge).not_to exist
      expect(quarantine_root.join("sample-catalog-service")).to be_symlink
      expect(File.readlink(quarantine_root.join("sample-catalog-service").to_s)).to eq(".support/sample-storefront/sample-catalog-service")
    end
  end

  it "rejects git metadata and unapproved targets" do
    Dir.mktmpdir("a3-rerun-quarantine-") do |dir|
      root = Pathname(dir)
      issue_workspace = root.join(".work", "a3", "issues", "sample", "sample-2700")
      repo = issue_workspace.join("sample-storefront")
      FileUtils.mkdir_p(repo.join(".git"))
      FileUtils.mkdir_p(repo.join("docs"))

      expect do
        described_class.quarantine_paths(
          issue_workspace: issue_workspace,
          quarantine_root: root.join("quarantine"),
          paths: [repo.join(".git")]
        )
      end.to raise_error(RuntimeError, /git metadata/)

      expect do
        described_class.quarantine_paths(
          issue_workspace: issue_workspace,
          quarantine_root: root.join("quarantine"),
          paths: [repo.join("docs")]
        )
      end.to raise_error(RuntimeError, /allowed rerun quarantine target/)
    end
  end
end
