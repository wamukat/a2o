# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "tmpdir"

RUN_SCRIPT_SPEC_ROOT_DIR = Pathname(__dir__).join("..", "..").expand_path
ENV["A2O_ROOT_DIR"] ||= RUN_SCRIPT_SPEC_ROOT_DIR.to_s
ENV["A3_ROOT_DIR"] ||= RUN_SCRIPT_SPEC_ROOT_DIR.to_s
ENV["A3_ROOT_DEFAULT_PROJECT"] ||= "a2o-reference"
ENV["A3_ROOT_RUNTIME_CONFIG_PATH"] ||= ".work/a3/config/a2o-reference-runtime.json"
ENV["A3_ROOT_CONFIG_DIR"] ||= "spec/fixtures/a3/config"
ENV["A3_ROOT_PREPARE_RUNTIME_CONFIG_SCRIPT"] ||= "spec/fixtures/a3/prepare_runtime_config.rb"
ENV["A3_ROOT_RUNTIME_CONFIG_PROJECTS"] ||= "a2o-reference"
ENV["A3_ROOT_RECONCILE_LIVE_PROCESS_PATTERN"] ||= "a2o-runtime-run-once"
ENV["A3_ROOT_LEGACY_DISABLED_MESSAGE"] ||= "Legacy A3Engine-v1 commands are disabled."

require "a3/operator/root_utility_launcher"

RSpec.describe A3RootUtilityLauncher do
  it "disables legacy A3Engine commands for a2o-reference" do
    expect { described_class.main(["describe-project", "--project", "a2o-reference"]) }
      .not_to raise_error
  end

  it "prints help through the A3 CLI root-utility entrypoint" do
    stdout, stderr, status = Open3.capture3(root_utility_env, *root_utility_command("--help"), chdir: described_class::ROOT_DIR.to_s)

    expect(status.success?).to eq(true), stderr
    expect(stdout).to include("Root utility launcher for A3 migration support.")
    expect(stdout).not_to include("describe-project")
  end

  it "fails fast for a legacy command through the A3 CLI root-utility entrypoint" do
    _stdout, stderr, status = Open3.capture3(
      root_utility_env,
      *root_utility_command("describe-project", "--project", "a2o-reference"),
      chdir: described_class::ROOT_DIR.to_s
    )

    expect(status.success?).to eq(false)
    expect(stderr).to include(described_class::LEGACY_A3ENGINE_DISABLED_MESSAGE)
  end

  it "delegates operational commands through the A3 CLI root-utility entrypoint" do
    Dir.mktmpdir("a3-run-wrapper-") do |temp_dir|
      root = Pathname(temp_dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      agent_jobs = root.join("agent_jobs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      worker_runs.write(JSON.generate({ "runs" => {} }))
      agent_jobs.write(JSON.generate({}))

      stdout, _stderr, status = Open3.capture3(
        root_utility_env,
        *root_utility_command(
          "describe-state",
          "--project", "a2o-reference",
          "--active-runs-file", active_runs.to_s,
          "--agent-jobs-file", agent_jobs.to_s
        ),
        chdir: described_class::ROOT_DIR.to_s
      )

      expect(status.success?).to eq(true)
      expect(JSON.parse(stdout).fetch("active_refs")).to eq([])
    end
  end

  it "delegates cleanup through the A3 CLI root-utility entrypoint" do
    Dir.mktmpdir("a3-run-cleanup-wrapper-") do |temp_dir|
      root = Pathname(temp_dir)
      fake_bin = root.join("bin")
      fake_task = fake_bin.join("task")
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      agent_jobs = root.join("agent_jobs.json")
      launcher = root.join("launcher.json")
      fake_bin.mkpath
      fake_task.write("#!/bin/sh\nprintf '[]\\n'\n")
      File.chmod(0o755, fake_task)
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      worker_runs.write(JSON.generate({ "runs" => {} }))
      agent_jobs.write(JSON.generate({}))
      launcher.write(JSON.generate({ "shell" => { "inherit_env" => true, "env_files" => [], "env_overrides" => {} } }))

      stdout, _stderr, status = Open3.capture3(
        root_utility_env("PATH" => "#{fake_bin}:#{ENV.fetch('PATH', '')}"),
        *root_utility_command(
          "cleanup",
          "--project", "a2o-reference",
          "--active-runs-file", active_runs.to_s,
          "--agent-jobs-file", agent_jobs.to_s,
          "--launcher-config", launcher.to_s
        ),
        chdir: described_class::ROOT_DIR.to_s
      )

      expect(status.success?).to eq(true)
      expect(JSON.parse(stdout).fetch("mode")).to eq("cleanup")
    end
  end

  it "delegates reconcile through the A3 CLI root-utility entrypoint" do
    Dir.mktmpdir("a3-run-reconcile-wrapper-") do |temp_dir|
      root = Pathname(temp_dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      agent_jobs = root.join("agent_jobs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      worker_runs.write(JSON.generate({ "runs" => {} }))
      agent_jobs.write(JSON.generate({}))

      stdout, _stderr, status = Open3.capture3(
        root_utility_env,
        *root_utility_command(
          "reconcile-active-runs",
          "--project", "a2o-reference",
          "--active-runs-file", active_runs.to_s,
          "--agent-jobs-file", agent_jobs.to_s
        ),
        chdir: described_class::ROOT_DIR.to_s
      )

      expect(status.success?).to eq(true)
      expect(JSON.parse(stdout).fetch("applied")).to eq(false)
    end
  end

  it "delegates doctor-env through the A3 CLI root-utility entrypoint with explicit launcher config" do
    Dir.mktmpdir("a3-run-doctor-wrapper-") do |temp_dir|
      launcher = Pathname(temp_dir).join("launcher.json")
      launcher.write(
        JSON.generate(
          "scheduler" => { "backend" => "manual" },
          "kanban" => { "backend" => "subprocess-cli" },
          "shell" => { "inherit_env" => true, "env_files" => [], "env_overrides" => {} },
          "runtime_env" => { "required_bins" => [], "path_entries" => [] }
        )
      )

      stdout, _stderr, status = Open3.capture3(
        root_utility_env,
        *root_utility_command(
          "doctor-env",
          "--project", "a2o-reference",
          "--launcher-config", launcher.to_s
        ),
        chdir: described_class::ROOT_DIR.to_s
      )

      expect(status.success?).to eq(true)
      expect(JSON.parse(stdout).fetch("launcher_config")).to eq(launcher.to_s)
    end
  end

  it "round-trips pause and resume scheduler state" do
    Dir.mktmpdir("a3-run-pause-roundtrip-") do |temp_dir|
      root = Pathname(temp_dir)
      stub_const("A3RootUtilityLauncher::ROOT_DIR", root)

      pause_rc = described_class.main(["pause-scheduler", "--project", "a2o-reference", "--reason", "operator"])
      pause_file = root.join(".work", "a3", "state", "a2o-reference", "scheduler-paused.json")
      expect(pause_rc).to eq(0)
      expect(pause_file).to exist
      expect(JSON.parse(pause_file.read).fetch("reason")).to eq("operator")

      resume_rc = described_class.main(["resume-scheduler", "--project", "a2o-reference"])
      expect(resume_rc).to eq(0)
      expect(pause_file).not_to exist
    end
  end

  it "matches immediate describe-scheduler-control output after pause and resume" do
    Dir.mktmpdir("a3-run-pause-describe-") do |temp_dir|
      root = Pathname(temp_dir)
      stub_const("A3RootUtilityLauncher::ROOT_DIR", root)

      pause_stdout = capture_stdout { expect(described_class.main(["pause-scheduler", "--project", "a2o-reference", "--reason", "operator"])).to eq(0) }
      describe_pause = capture_stdout { expect(described_class.main(["describe-scheduler-control", "--project", "a2o-reference"])).to eq(0) }
      resume_stdout = capture_stdout { expect(described_class.main(["resume-scheduler", "--project", "a2o-reference"])).to eq(0) }
      describe_resume = capture_stdout { expect(described_class.main(["describe-scheduler-control", "--project", "a2o-reference"])).to eq(0) }

      expect(JSON.parse(pause_stdout)).to eq(JSON.parse(describe_pause))
      expect(JSON.parse(resume_stdout)).to eq(JSON.parse(describe_resume))
    end
  end

  it "uses runtime config defaults for cleanup" do
    allow(A3Cleanup).to receive(:main).and_return(0)

    rc = described_class.main(["cleanup", "--project", "a2o-reference"])

    expect(rc).to eq(0)
    expect(A3Cleanup).to have_received(:main).with(
      [
        "--project", "a2o-reference",
        "--kanban-project", "A2OReferenceMultiRepo",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "active-runs.json").to_s,
        "--agent-jobs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json").to_s,
        "--launcher-config", described_class::RUNTIME_CONFIG.to_s,
        "--done-ttl-hours", "24",
        "--blocked-ttl-hours", "24",
        "--result-ttl-hours", "168",
        "--log-ttl-hours", "168",
        "--quarantine-ttl-hours", "168",
        "--cache-ttl-hours", "168",
        "--build-output-ttl-hours", "168"
      ]
    )
  end

  it "passes explicit cleanup count budgets through to the root script" do
    allow(A3Cleanup).to receive(:main).and_return(0)

    rc = described_class.main(
      [
        "cleanup",
        "--project", "a2o-reference",
        "--max-quarantine-count", "5",
        "--max-result-count", "10",
        "--max-log-count", "8"
      ]
    )

    expect(rc).to eq(0)
    expect(A3Cleanup).to have_received(:main).with(
      [
        "--project", "a2o-reference",
        "--kanban-project", "A2OReferenceMultiRepo",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "active-runs.json").to_s,
        "--agent-jobs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json").to_s,
        "--launcher-config", described_class::RUNTIME_CONFIG.to_s,
        "--done-ttl-hours", "24",
        "--blocked-ttl-hours", "24",
        "--result-ttl-hours", "168",
        "--log-ttl-hours", "168",
        "--quarantine-ttl-hours", "168",
        "--cache-ttl-hours", "168",
        "--build-output-ttl-hours", "168",
        "--max-quarantine-count", "5",
        "--max-result-count", "10",
        "--max-log-count", "8"
      ]
    )
  end

  it "passes explicit cleanup size budgets through to the root script" do
    allow(A3Cleanup).to receive(:main).and_return(0)

    rc = described_class.main(
      [
        "cleanup",
        "--project", "a2o-reference",
        "--max-quarantine-bytes", "1024",
        "--max-result-bytes", "2048",
        "--max-log-bytes", "4096",
        "--max-cache-bytes", "8192"
      ]
    )

    expect(rc).to eq(0)
    expect(A3Cleanup).to have_received(:main).with(
      [
        "--project", "a2o-reference",
        "--kanban-project", "A2OReferenceMultiRepo",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "active-runs.json").to_s,
        "--agent-jobs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json").to_s,
        "--launcher-config", described_class::RUNTIME_CONFIG.to_s,
        "--done-ttl-hours", "24",
        "--blocked-ttl-hours", "24",
        "--result-ttl-hours", "168",
        "--log-ttl-hours", "168",
        "--quarantine-ttl-hours", "168",
        "--cache-ttl-hours", "168",
        "--build-output-ttl-hours", "168",
        "--max-quarantine-bytes", "1024",
        "--max-result-bytes", "2048",
        "--max-log-bytes", "4096",
        "--max-cache-bytes", "8192"
      ]
    )
  end

  it "passes build output cleanup options through to the root script" do
    allow(A3Cleanup).to receive(:main).and_return(0)

    rc = described_class.main(
      [
        "cleanup",
        "--project", "a2o-reference",
        "--build-output-ttl-hours", "72",
        "--max-build-output-bytes", "16384"
      ]
    )

    expect(rc).to eq(0)
    expect(A3Cleanup).to have_received(:main).with(
      [
        "--project", "a2o-reference",
        "--kanban-project", "A2OReferenceMultiRepo",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "active-runs.json").to_s,
        "--agent-jobs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json").to_s,
        "--launcher-config", described_class::RUNTIME_CONFIG.to_s,
        "--done-ttl-hours", "24",
        "--blocked-ttl-hours", "24",
        "--result-ttl-hours", "168",
        "--log-ttl-hours", "168",
        "--quarantine-ttl-hours", "168",
        "--cache-ttl-hours", "168",
        "--build-output-ttl-hours", "72",
        "--max-build-output-bytes", "16384"
      ]
    )
  end

  it "uses runtime config defaults for reconcile-active-runs" do
    allow(described_class).to receive(:run_reconcile_command).and_return(0)

    rc = described_class.main(["reconcile-active-runs", "--project", "a2o-reference", "--status", "To do", "--apply"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_reconcile_command).with(
      [
        "--project", "a2o-reference",
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "active-runs.json").to_s,
        "--agent-jobs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json").to_s,
        "--live-process-pattern", "a2o-runtime-run-once",
        "--live-process-pattern", "a2o-reference-kanban-scheduler-auto",
        "--launcher-config", described_class::RUNTIME_CONFIG.to_s,
        "--status", "To do",
        "--apply"
      ]
    )
  end

  it "uses project defaults for quarantine-rerun-artifacts" do
    allow(A3RerunQuarantine).to receive(:main).and_return(0)

    rc = described_class.main(["quarantine-rerun-artifacts", "--project", "a2o-reference", "--task-ref", "A2OReferenceMultiRepo#2700"])

    expect(rc).to eq(0)
    expect(A3RerunQuarantine).to have_received(:main).with(
      [
        "--project", "a2o-reference",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--task-ref", "A2OReferenceMultiRepo#2700"
      ]
    )
  end

  it "uses project defaults for check-rerun-readiness" do
    allow(A3RerunReadiness).to receive(:main).and_return(0)

    rc = described_class.main(["check-rerun-readiness", "--project", "a2o-reference", "--task-ref", "A2OReferenceMultiRepo#2700"])

    expect(rc).to eq(0)
    expect(A3RerunReadiness).to have_received(:main).with(
      [
        "--project", "a2o-reference",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--task-ref", "A2OReferenceMultiRepo#2700",
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "active-runs.json").to_s,
        "--agent-jobs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json").to_s,
        "--kanban-project", "A2OReferenceMultiRepo"
      ],
      default_kanban_working_dir: described_class::ROOT_DIR
    )
  end

  it "uses project defaults for describe-state" do
    allow(described_class).to receive(:run_diagnostics_command).and_return(0)

    rc = described_class.main(["describe-state", "--project", "a2o-reference"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_diagnostics_command).with(
      [
        "describe-state",
        "--project", "a2o-reference",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "active-runs.json").to_s,
        "--agent-jobs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json").to_s
      ]
    )
  end

  it "emits selected and projected states through diagnostics" do
    Dir.mktmpdir("a3-run-describe-state-") do |temp_dir|
      root = Pathname(temp_dir)
      active_runs = root.join(".work", "a3", "state", "a2o-reference", "active-runs.json")
      worker_runs = root.join(".work", "a3", "state", "a2o-reference", "worker-runs.json")
      agent_jobs = root.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json")
      active_runs.dirname.mkpath
      active_runs.write(JSON.generate({ "active_task_refs" => ["A2OReferenceMultiRepo#1"] }))
      agent_jobs.write(
        JSON.generate(
          {
            "job-1" => {
              "state" => "completed",
              "claimed_at" => "2026-03-30T00:00:00+00:00",
              "heartbeat_at" => "2026-03-30T00:00:01+00:00",
              "request" => {
                "job_id" => "job-1",
                "task_ref" => "A2OReferenceMultiRepo#1",
                "phase" => "implementation",
                "command" => "worker",
                "args" => [],
                "working_dir" => root.to_s
              },
              "result" => { "status" => "succeeded", "activity_state" => "selected" }
            },
            "job-2" => {
              "state" => "completed",
              "claimed_at" => "2026-03-30T00:00:00+00:00",
              "heartbeat_at" => "2026-03-30T00:00:01+00:00",
              "request" => {
                "job_id" => "job-2",
                "task_ref" => "A2OReferenceMultiRepo#2",
                "phase" => "planner",
                "command" => "worker",
                "args" => [],
                "working_dir" => root.to_s
              },
              "result" => { "status" => "failed", "activity_state" => "blocked_task_failure" }
            }
          }
        )
      )
      stub_const("A3RootUtilityLauncher::ROOT_DIR", root)

      stdout = capture_stdout { expect(described_class.main(["describe-state", "--project", "a2o-reference"])).to eq(0) }
      payload = JSON.parse(stdout)
      expect(payload.fetch("selected_pending_refs")).to eq(["A2OReferenceMultiRepo#1"])
      recent_by_ref = payload.fetch("recent_runs").to_h { |item| [item.fetch("task_ref"), item] }
      expect(recent_by_ref.fetch("A2OReferenceMultiRepo#2").fetch("state")).to eq("blocked_task_failure")
    end
  end

  it "uses project defaults for watch" do
    allow(described_class).to receive(:run_diagnostics_command).and_return(0)

    rc = described_class.main(["watch", "--project", "a2o-reference", "--interval", "3", "--iterations", "4"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_diagnostics_command).with(
      [
        "watch",
        "--project", "a2o-reference",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "active-runs.json").to_s,
        "--agent-jobs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "a2o-reference", "agent_jobs.json").to_s,
        "--interval", "3.0",
        "--iterations", "4"
      ]
    )
  end

  it "uses runtime config for doctor-env" do
    allow(described_class).to receive(:run_diagnostics_command).and_return(0)

    rc = described_class.main(["doctor-env", "--project", "a2o-reference"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_diagnostics_command).with(
      [
        "doctor-env",
        "--launcher-config", described_class::RUNTIME_CONFIG.to_s
      ]
    )
  end

  it "propagates a2o-reference runtime config prepare failures for a2o-reference doctor-env" do
    allow(described_class).to receive(:run_prepare_runtime_config).and_return(7)

    rc = described_class.main(["doctor-env", "--project", "a2o-reference"])

    expect(rc).to eq(7)
  end

  it "uses internally materialized runtime config for a2o-reference doctor-env" do
    allow(described_class).to receive(:run_prepare_runtime_config).and_return(0)
    allow(described_class).to receive(:run_diagnostics_command).and_return(0)

    rc = described_class.main(["doctor-env", "--project", "a2o-reference"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_diagnostics_command).with(
      [
        "doctor-env",
        "--launcher-config", described_class::RUNTIME_CONFIG.to_s
      ]
    )
  end

  def capture_stdout
    original_stdout = $stdout
    output = StringIO.new
    $stdout = output
    yield
    output.string
  ensure
    $stdout = original_stdout
  end

  def root_utility_command(*args)
    ["bin/a3", "root-utility", *args]
  end

  def root_utility_env(extra = {})
    ENV.to_h.merge("RUBYLIB" => "a3-engine/lib").merge(extra)
  end
end
