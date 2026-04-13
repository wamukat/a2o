# frozen_string_literal: true

require "tmpdir"
require_relative "../../../scripts/a3-projects/portal/portal_scheduler_launcher"

RSpec.describe PortalSchedulerLauncher do
  it "builds execute-until-idle command with portal trigger labels" do
    config = described_class::SchedulerConfig.new(storage_dir: Pathname("/tmp/storage"), max_steps: 16)

    allow(described_class).to receive(:repo_sources).and_return(repo_alpha: Pathname("/live/starters"), repo_beta: Pathname("/live/ui"))

    command = described_class.build_command(config)

    expect(command).to include("--kanban-status", "To do")
    expect(command).to include("trigger:auto-implement")
    expect(command).to include("trigger:auto-parent")
    expect(command).to include("repo:both=repo_alpha,repo_beta")
    expect(command).to include("repo_alpha=/live/starters")
    expect(command).to include("repo_beta=/live/ui")
  end

  it "dispatches detached run-shot process" do
    allow(described_class).to receive(:build_run_shot_command).and_return(["ruby", "/repo/scripts/a3-projects/portal/portal_scheduler_launcher.rb", "--run-shot"])
    allow(Process).to receive(:spawn).and_return(43_210)
    allow(Process).to receive(:detach)

    rc = described_class.dispatch_scheduler(env: { "PATH" => "/bin" })

    expect(rc).to eq(0)
    expect(Process).to have_received(:spawn).with(
      { "PATH" => "/bin" },
      "ruby",
      "/repo/scripts/a3-projects/portal/portal_scheduler_launcher.rb",
      "--run-shot",
      chdir: described_class::ROOT_DIR.to_s,
      in: File::NULL,
      pgroup: true
    )
    expect(Process).to have_received(:detach).with(43_210)
  end

  it "runs execute-until-idle when the scheduler-shot lock is available" do
    Dir.mktmpdir do |dir|
      config = described_class::SchedulerConfig.new(storage_dir: Pathname(dir), max_steps: 16)
      lock_path = config.shot_lock_path
      lock_path.dirname.mkpath
      lock_handle = lock_path.open(File::RDWR | File::CREAT, 0o644)

      allow(described_class).to receive(:scheduler_config).and_return(config)
      allow(described_class).to receive(:build_command).and_return(["ruby", "a3-v2/bin/a3", "execute-until-idle"])
      allow(described_class).to receive(:acquire_shot_lock).with(lock_path).and_return(lock_handle)
      allow(described_class).to receive(:system).and_return(true)

      rc = described_class.run_shot(env: { "PATH" => "/bin" })

      expect(rc).to eq(0)
      expect(described_class).to have_received(:system).with(
        { "PATH" => "/bin" },
        "ruby",
        "a3-v2/bin/a3",
        "execute-until-idle",
        chdir: described_class::ROOT_DIR.to_s,
        in: File::NULL
      )
      expect(lock_path).not_to exist
      lock_handle.close unless lock_handle.closed?
    end
  end

  it "returns zero without spawning when another shot holds the lock" do
    allow(described_class).to receive(:acquire_shot_lock).and_return(nil)

    rc = described_class.run_shot(env: { "PATH" => "/bin" })

    expect(rc).to eq(0)
  end

  it "acquires the lock only once" do
    Dir.mktmpdir do |dir|
      lock_path = Pathname(dir).join("scheduler-shot.lock")
      first = described_class.acquire_shot_lock(lock_path)
      expect(first).not_to be_nil
      second = described_class.acquire_shot_lock(lock_path)
      expect(second).to be_nil
      first.flock(File::LOCK_UN)
      first.close
    end
  end
end
