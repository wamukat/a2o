# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require_relative "../../../scripts/a3-projects/portal/inject/portal_verification"

RSpec.describe PortalVerification do
  def write_taskfile(slot_path)
    File.write(slot_path.join("Taskfile.yml"), "version: '3'\n")
  end

  def write_slot_metadata(slot_path, repo_name)
    metadata_dir = slot_path.join(".a3")
    FileUtils.mkdir_p(metadata_dir)
    File.write(metadata_dir.join("slot.json"), JSON.generate({ "repo_source_root" => "/tmp/#{repo_name}" }))
  end

  def write_workspace_metadata(workspace_root, source_ref)
    metadata_dir = workspace_root.join(".a3")
    FileUtils.mkdir_p(metadata_dir)
    File.write(metadata_dir.join("workspace.json"), JSON.generate({ "source_ref" => source_ref }))
  end

  it "runs child inspection commands for each available slot" do
    Dir.mktmpdir("portal-v2-verification-") do |tmpdir|
      workspace_root = Pathname(tmpdir)
      repo_alpha = workspace_root.join("repo-alpha")
      repo_beta = workspace_root.join("repo-beta")
      FileUtils.mkdir_p([repo_alpha, repo_beta])
      write_taskfile(repo_alpha)
      write_taskfile(repo_beta)
      write_slot_metadata(repo_alpha, "member-portal-starters")
      write_slot_metadata(repo_beta, "member-portal-ui-app")
      write_workspace_metadata(workspace_root, "refs/heads/a3/work/Portal-3153")

      allow(described_class).to receive(:run_command)

      result = described_class.run_slot_commands(workspace_root, base_env: {})

      expect(result).to eq(0)
      expected_env = {
        "AUTOMATION_ISSUE_WORKSPACE" => workspace_root.to_s,
        "MAVEN_REPO_LOCAL" => workspace_root.join(".work", "m2", "repository").to_s,
        "A3_ROOT_DIR" => described_class::ROOT_DIR.to_s
      }
      expect(described_class).to have_received(:run_command).with(["task", "test:nullaway"], cwd: repo_alpha, env: expected_env).ordered
      expect(described_class).to have_received(:run_command).with(
        [
          "bash",
          described_class::ROOT_DIR.join("scripts", "a3-projects", "portal", "bootstrap-phase-support-maven.sh").to_s,
          "member-portal-ui-app",
          repo_alpha.to_s
        ],
        cwd: repo_beta,
        env: expected_env
      ).ordered
      expect(described_class).to have_received(:run_command).with(["task", "test:nullaway"], cwd: repo_beta, env: expected_env).ordered
    end
  end

  it "fails when no workspace slots are available" do
    Dir.mktmpdir("portal-v2-verification-") do |tmpdir|
      expect do
        described_class.run_slot_commands(Pathname(tmpdir), base_env: {})
      end.to raise_error(RuntimeError, /no verifiable workspace slots found/)
    end
  end

  it "fails when slot taskfile is missing" do
    Dir.mktmpdir("portal-v2-verification-") do |tmpdir|
      workspace_root = Pathname(tmpdir)
      FileUtils.mkdir_p(workspace_root.join("repo-beta"))

      expect do
        described_class.run_slot_commands(workspace_root, base_env: {})
      end.to raise_error(RuntimeError, /missing Taskfile.yml/)
    end
  end

  it "fails when workspace metadata is missing" do
    Dir.mktmpdir("portal-v2-verification-") do |tmpdir|
      workspace_root = Pathname(tmpdir)
      slot_path = workspace_root.join("repo-alpha")
      FileUtils.mkdir_p(slot_path)
      write_taskfile(slot_path)

      expect do
        described_class.run_slot_commands(workspace_root, base_env: {})
      end.to raise_error(RuntimeError, /missing metadata file/)
    end
  end

  it "fails when ui-app verification cannot find the materialized starters support slot" do
    Dir.mktmpdir("portal-v2-verification-") do |tmpdir|
      workspace_root = Pathname(tmpdir)
      repo_beta = workspace_root.join("repo-beta")
      FileUtils.mkdir_p(repo_beta)
      write_taskfile(repo_beta)
      write_slot_metadata(repo_beta, "member-portal-ui-app")
      write_workspace_metadata(workspace_root, "refs/heads/a3/work/Portal-3153")

      allow(described_class).to receive(:bootstrap_maven_repo)
      allow(described_class).to receive(:prefetch_mockito_agent)
      allow(described_class).to receive(:run_command)

      expect do
        described_class.run_slot_commands(workspace_root, base_env: {})
      end.to raise_error(RuntimeError, /missing materialized support slot for member-portal-starters/)
    end
  end

  it "runs parent inspection commands per repo" do
    Dir.mktmpdir("portal-v2-verification-") do |tmpdir|
      workspace_root = Pathname(tmpdir)
      repo_alpha = workspace_root.join("repo-alpha")
      repo_beta = workspace_root.join("repo-beta")
      FileUtils.mkdir_p([repo_alpha, repo_beta])
      write_taskfile(repo_alpha)
      write_taskfile(repo_beta)
      write_slot_metadata(repo_alpha, "member-portal-ui-app")
      write_slot_metadata(repo_beta, "member-portal-starters")
      write_workspace_metadata(workspace_root, "refs/heads/a3/parent/Portal-3153")

      allow(described_class).to receive(:run_command)

      result = described_class.run_slot_commands(workspace_root, base_env: {})

      expect(result).to eq(0)
      expected_env = {
        "AUTOMATION_ISSUE_WORKSPACE" => workspace_root.to_s,
        "MAVEN_REPO_LOCAL" => workspace_root.join(".work", "m2", "repository").to_s,
        "A3_ROOT_DIR" => described_class::ROOT_DIR.to_s
      }
      expect(described_class).to have_received(:run_command).with(
        [
          "bash",
          described_class::ROOT_DIR.join("scripts", "a3-projects", "portal", "bootstrap-phase-support-maven.sh").to_s,
          "member-portal-ui-app",
          repo_beta.to_s
        ],
        cwd: repo_alpha,
        env: expected_env
      ).ordered
      expect(described_class).to have_received(:run_command).with(["task", "gate:standard"], cwd: repo_alpha, env: expected_env).ordered
      expect(described_class).to have_received(:run_command).with(["task", "test:nullaway"], cwd: repo_alpha, env: expected_env).ordered
      expect(described_class).to have_received(:run_command).with(["task", "gate:standard"], cwd: repo_beta, env: expected_env).ordered
      expect(described_class).to have_received(:run_command).with(["task", "test:all"], cwd: repo_beta, env: expected_env).ordered
      expect(described_class).to have_received(:run_command).with(["task", "test:nullaway"], cwd: repo_beta, env: expected_env).ordered
    end
  end
end
