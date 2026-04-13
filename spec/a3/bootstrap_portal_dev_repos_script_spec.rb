# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require_relative "../../../scripts/a3-projects/portal/support/bootstrap_portal_dev_repos"

RSpec.describe BootstrapPortalDevRepos do
  def run_capture(*args, cwd:)
    stdout, stderr, status = Open3.capture3(*args, chdir: cwd.to_s)
    raise "command failed: #{args.join(' ')}\nstdout=#{stdout}\nstderr=#{stderr}" unless status.success?

    stdout.strip
  end

  def init_repo(path)
    FileUtils.mkdir_p(path)
    run_capture("git", "init", "-b", "main", cwd: path)
    run_capture("git", "config", "user.name", "A3 Test", cwd: path)
    run_capture("git", "config", "user.email", "a3@example.com", cwd: path)
    path.join("README.md").write("seed\n")
    run_capture("git", "add", "README.md", cwd: path)
    run_capture("git", "commit", "-m", "seed", cwd: path)
  end

  it "materializes source head on local main branch for dev repo and live target" do
    Dir.mktmpdir("portal-dev-bootstrap-") do |temp_dir|
      root = Pathname(temp_dir)
      source = root.join("source", "member-portal-ui-app")
      init_repo(source)
      run_capture("git", "checkout", "-b", "feature/prototype", cwd: source)
      source.join("Taskfile.yml").write("version: '3'\n")
      source.join("mvnw").write("#!/bin/sh\n")
      source.join("pom.xml").write("<project/>\n")
      run_capture("git", "add", "Taskfile.yml", "mvnw", "pom.xml", cwd: source)
      run_capture("git", "commit", "-m", "feature contents", cwd: source)
      source_head = run_capture("git", "rev-parse", "HEAD", cwd: source)

      payload = described_class.bootstrap_portal_dev_repos(
        dev_repos_dir: root.join("dev"),
        live_targets_dir: root.join("live-targets"),
        source_repos: { "member-portal-ui-app" => source }
      )

      destination = root.join("dev", "member-portal-ui-app")
      live_target = root.join("live-targets", "member-portal-ui-app")
      expect(destination.join("Taskfile.yml")).to exist
      expect(live_target.join("Taskfile.yml")).to exist
      expect(run_capture("git", "branch", "--show-current", cwd: destination)).to eq("main")
      expect(run_capture("git", "branch", "--show-current", cwd: live_target)).to eq("main")
      expect(run_capture("git", "rev-parse", "HEAD", cwd: destination)).to eq(source_head)
      expect(run_capture("git", "rev-parse", "HEAD", cwd: live_target)).to eq(source_head)
      expect(run_capture("git", "rev-parse", "a3/issue", cwd: destination)).to eq(source_head)
      expect(run_capture("git", "rev-parse", "a3/parent", cwd: destination)).to eq(source_head)
      expect(payload.fetch("repos").fetch(0).fetch("source_branch")).to eq("feature/prototype")
      expect(payload.fetch("repos").fetch(0).fetch("source_head")).to eq(source_head)
      expect(payload.fetch("repos").fetch(0).fetch("topology_heads")).to eq(
        "a3/issue" => source_head,
        "a3/parent" => source_head
      )
    end
  end

  it "refreshes existing clones to the latest source head" do
    Dir.mktmpdir("portal-dev-bootstrap-") do |temp_dir|
      root = Pathname(temp_dir)
      source = root.join("source", "member-portal-starters")
      init_repo(source)

      described_class.bootstrap_portal_dev_repos(
        dev_repos_dir: root.join("dev"),
        live_targets_dir: root.join("live-targets"),
        source_repos: { "member-portal-starters" => source }
      )

      run_capture("git", "checkout", "-b", "feature/prototype", cwd: source)
      source.join("Taskfile.yml").write("version: '3'\n")
      run_capture("git", "add", "Taskfile.yml", cwd: source)
      run_capture("git", "commit", "-m", "add taskfile", cwd: source)
      latest_head = run_capture("git", "rev-parse", "HEAD", cwd: source)

      payload = described_class.bootstrap_portal_dev_repos(
        dev_repos_dir: root.join("dev"),
        live_targets_dir: root.join("live-targets"),
        source_repos: { "member-portal-starters" => source }
      )

      destination = root.join("dev", "member-portal-starters")
      live_target = root.join("live-targets", "member-portal-starters")
      expect(run_capture("git", "branch", "--show-current", cwd: destination)).to eq("main")
      expect(run_capture("git", "branch", "--show-current", cwd: live_target)).to eq("main")
      expect(run_capture("git", "rev-parse", "HEAD", cwd: destination)).to eq(latest_head)
      expect(run_capture("git", "rev-parse", "HEAD", cwd: live_target)).to eq(latest_head)
      expect(run_capture("git", "rev-parse", "a3/issue", cwd: destination)).to eq(latest_head)
      expect(run_capture("git", "rev-parse", "a3/parent", cwd: destination)).to eq(latest_head)
      expect(payload.fetch("repos").fetch(0).fetch("action")).to eq("updated")
    end
  end

  it "fetches a detached source head on refresh" do
    Dir.mktmpdir("portal-dev-bootstrap-") do |temp_dir|
      root = Pathname(temp_dir)
      source = root.join("source", "member-portal-ui-app")
      init_repo(source)

      described_class.bootstrap_portal_dev_repos(
        dev_repos_dir: root.join("dev"),
        live_targets_dir: root.join("live-targets"),
        source_repos: { "member-portal-ui-app" => source }
      )

      run_capture("git", "checkout", "-b", "feature/prototype", cwd: source)
      source.join("Taskfile.yml").write("version: '3'\n")
      run_capture("git", "add", "Taskfile.yml", cwd: source)
      run_capture("git", "commit", "-m", "add taskfile", cwd: source)
      detached_head = run_capture("git", "rev-parse", "HEAD", cwd: source)
      run_capture("git", "checkout", "--detach", detached_head, cwd: source)
      run_capture("git", "branch", "-D", "feature/prototype", cwd: source)

      payload = described_class.bootstrap_portal_dev_repos(
        dev_repos_dir: root.join("dev"),
        live_targets_dir: root.join("live-targets"),
        source_repos: { "member-portal-ui-app" => source }
      )

      destination = root.join("dev", "member-portal-ui-app")
      live_target = root.join("live-targets", "member-portal-ui-app")
      expect(run_capture("git", "rev-parse", "HEAD", cwd: destination)).to eq(detached_head)
      expect(run_capture("git", "rev-parse", "HEAD", cwd: live_target)).to eq(detached_head)
      expect(run_capture("git", "rev-parse", "a3/issue", cwd: destination)).to eq(detached_head)
      expect(run_capture("git", "rev-parse", "a3/parent", cwd: destination)).to eq(detached_head)
      expect(payload.fetch("repos").fetch(0).fetch("source_branch")).to eq("HEAD")
    end
  end

  it "fails closed when an existing dev clone is dirty" do
    Dir.mktmpdir("portal-dev-bootstrap-") do |temp_dir|
      root = Pathname(temp_dir)
      source = root.join("source", "member-portal-ui-app")
      init_repo(source)

      described_class.bootstrap_portal_dev_repos(
        dev_repos_dir: root.join("dev"),
        live_targets_dir: root.join("live-targets"),
        source_repos: { "member-portal-ui-app" => source }
      )

      destination = root.join("dev", "member-portal-ui-app")
      destination.join("README.md").write("dirty\n")

      expect do
        described_class.bootstrap_portal_dev_repos(
          dev_repos_dir: root.join("dev"),
          live_targets_dir: root.join("live-targets"),
          source_repos: { "member-portal-ui-app" => source }
        )
      end.to raise_error(RuntimeError, /isolated dev repository is dirty/)
    end
  end

  it "fails closed when an existing live target origin mismatches the source" do
    Dir.mktmpdir("portal-dev-bootstrap-") do |temp_dir|
      root = Pathname(temp_dir)
      source = root.join("source", "member-portal-ui-app")
      rogue = root.join("rogue", "member-portal-ui-app")
      init_repo(source)
      init_repo(rogue)

      described_class.bootstrap_portal_dev_repos(
        dev_repos_dir: root.join("dev"),
        live_targets_dir: root.join("live-targets"),
        source_repos: { "member-portal-ui-app" => source }
      )

      live_target = root.join("live-targets", "member-portal-ui-app")
      run_capture("git", "remote", "set-url", "origin", rogue.to_s, cwd: live_target)

      expect do
        described_class.bootstrap_portal_dev_repos(
          dev_repos_dir: root.join("dev"),
          live_targets_dir: root.join("live-targets"),
          source_repos: { "member-portal-ui-app" => source }
        )
      end.to raise_error(RuntimeError, /live target repository origin does not match expected source/)
    end
  end

  it "runs as a standalone script process" do
    Dir.mktmpdir("portal-dev-bootstrap-script-") do |temp_dir|
      root = Pathname(temp_dir)
      ui_app = root.join("member-portal-ui-app")
      starters = root.join("member-portal-starters")
      init_repo(ui_app)
      init_repo(starters)

      stdout, stderr, status = Open3.capture3(
        "ruby",
        described_class.method(:main).source_location.first,
        "--dev-repos-dir", root.join("dev").to_s,
        "--live-targets-dir", root.join("live-targets").to_s,
        "--source-repo", "member-portal-ui-app=#{ui_app}",
        "--source-repo", "member-portal-starters=#{starters}"
      )

      expect(status.success?).to eq(true), stderr
      payload = JSON.parse(stdout)
      expect(payload.fetch("repos").size).to eq(2)
      expect(root.join("dev", "member-portal-ui-app")).to exist
      expect(root.join("live-targets", "member-portal-starters")).to exist
    end
  end
end
