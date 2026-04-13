# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require_relative "../../../scripts/a3/run"

RSpec.describe A3RootUtilityLauncher do
  it "disables legacy A3Engine commands for portal-dev" do
    expect { described_class.main(["describe-project", "--project", "portal-dev"]) }
      .not_to raise_error
  end

  it "prints help as a direct CLI entrypoint" do
    stdout, stderr, status = Open3.capture3("ruby", "scripts/a3/run.rb", "--help", chdir: described_class::ROOT_DIR.to_s)

    expect(status.success?).to eq(true), stderr
    expect(stdout).to include("Root utility launcher for A3 migration support.")
    expect(stdout).not_to include("describe-project")
  end

  it "fails fast for a legacy command as a direct CLI entrypoint" do
    _stdout, stderr, status = Open3.capture3(
      "ruby", "scripts/a3/run.rb", "describe-project", "--project", "portal-dev", chdir: described_class::ROOT_DIR.to_s
    )

    expect(status.success?).to eq(false)
    expect(stderr).to include(described_class::LEGACY_A3ENGINE_DISABLED_MESSAGE)
  end

  it "round-trips pause and resume scheduler state" do
    Dir.mktmpdir("a3-run-pause-roundtrip-") do |temp_dir|
      root = Pathname(temp_dir)
      stub_const("A3RootUtilityLauncher::ROOT_DIR", root)

      pause_rc = described_class.main(["pause-scheduler", "--project", "portal-dev", "--reason", "operator"])
      pause_file = root.join(".work", "a3", "state", "portal-dev", "scheduler-paused.json")
      expect(pause_rc).to eq(0)
      expect(pause_file).to exist
      expect(JSON.parse(pause_file.read).fetch("reason")).to eq("operator")

      resume_rc = described_class.main(["resume-scheduler", "--project", "portal-dev"])
      expect(resume_rc).to eq(0)
      expect(pause_file).not_to exist
    end
  end

  it "matches immediate describe-scheduler-control output after pause and resume" do
    Dir.mktmpdir("a3-run-pause-describe-") do |temp_dir|
      root = Pathname(temp_dir)
      stub_const("A3RootUtilityLauncher::ROOT_DIR", root)

      pause_stdout = capture_stdout { expect(described_class.main(["pause-scheduler", "--project", "portal-dev", "--reason", "operator"])).to eq(0) }
      describe_pause = capture_stdout { expect(described_class.main(["describe-scheduler-control", "--project", "portal-dev"])).to eq(0) }
      resume_stdout = capture_stdout { expect(described_class.main(["resume-scheduler", "--project", "portal-dev"])).to eq(0) }
      describe_resume = capture_stdout { expect(described_class.main(["describe-scheduler-control", "--project", "portal-dev"])).to eq(0) }

      expect(JSON.parse(pause_stdout)).to eq(JSON.parse(describe_pause))
      expect(JSON.parse(resume_stdout)).to eq(JSON.parse(describe_resume))
    end
  end

  it "uses project defaults for cleanup" do
    allow(described_class).to receive(:run_simple_script).and_return(0)

    rc = described_class.main(["cleanup", "--project", "portal-dev"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_simple_script).with(
      described_class::CLEANUP_SCRIPT,
      [
        "--project", "portal-dev",
        "--kanban-project", "Portal",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "active-runs.json").to_s,
        "--worker-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "worker-runs.json").to_s,
        "--launcher-config", described_class::CONFIG_DIR.join("portal-dev", "launcher.json").to_s,
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
    allow(described_class).to receive(:run_simple_script).and_return(0)

    rc = described_class.main(
      [
        "cleanup",
        "--project", "portal-dev",
        "--max-quarantine-count", "5",
        "--max-result-count", "10",
        "--max-log-count", "8"
      ]
    )

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_simple_script).with(
      described_class::CLEANUP_SCRIPT,
      [
        "--project", "portal-dev",
        "--kanban-project", "Portal",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "active-runs.json").to_s,
        "--worker-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "worker-runs.json").to_s,
        "--launcher-config", described_class::CONFIG_DIR.join("portal-dev", "launcher.json").to_s,
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
    allow(described_class).to receive(:run_simple_script).and_return(0)

    rc = described_class.main(
      [
        "cleanup",
        "--project", "portal-dev",
        "--max-quarantine-bytes", "1024",
        "--max-result-bytes", "2048",
        "--max-log-bytes", "4096",
        "--max-cache-bytes", "8192"
      ]
    )

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_simple_script).with(
      described_class::CLEANUP_SCRIPT,
      [
        "--project", "portal-dev",
        "--kanban-project", "Portal",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "active-runs.json").to_s,
        "--worker-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "worker-runs.json").to_s,
        "--launcher-config", described_class::CONFIG_DIR.join("portal-dev", "launcher.json").to_s,
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
    allow(described_class).to receive(:run_simple_script).and_return(0)

    rc = described_class.main(
      [
        "cleanup",
        "--project", "portal-dev",
        "--build-output-ttl-hours", "72",
        "--max-build-output-bytes", "16384"
      ]
    )

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_simple_script).with(
      described_class::CLEANUP_SCRIPT,
      [
        "--project", "portal-dev",
        "--kanban-project", "Portal",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "active-runs.json").to_s,
        "--worker-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "worker-runs.json").to_s,
        "--launcher-config", described_class::CONFIG_DIR.join("portal-dev", "launcher.json").to_s,
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

  it "uses project defaults for reconcile-active-runs" do
    allow(described_class).to receive(:run_reconcile_command).and_return(0)

    rc = described_class.main(["reconcile-active-runs", "--project", "portal-dev", "--status", "To do", "--apply"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_reconcile_command).with(
      [
        "--project", "portal-dev",
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "active-runs.json").to_s,
        "--worker-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "worker-runs.json").to_s,
        "--launcher-config", described_class::CONFIG_DIR.join("portal-dev", "launcher.json").to_s,
        "--status", "To do",
        "--apply"
      ]
    )
  end

  it "uses project defaults for quarantine-rerun-artifacts" do
    allow(described_class).to receive(:run_simple_script).and_return(0)

    rc = described_class.main(["quarantine-rerun-artifacts", "--project", "portal-dev", "--task-ref", "Portal#2700"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_simple_script).with(
      described_class::RERUN_QUARANTINE_SCRIPT,
      [
        "--project", "portal-dev",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--task-ref", "Portal#2700"
      ]
    )
  end

  it "uses project defaults for check-rerun-readiness" do
    allow(described_class).to receive(:run_simple_script).and_return(0)

    rc = described_class.main(["check-rerun-readiness", "--project", "portal-dev", "--task-ref", "Portal#2700"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_simple_script).with(
      described_class::RERUN_READINESS_SCRIPT,
      [
        "--project", "portal-dev",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--task-ref", "Portal#2700",
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "active-runs.json").to_s,
        "--worker-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "worker-runs.json").to_s,
        "--kanban-project", "Portal"
      ]
    )
  end

  it "uses project defaults for describe-state" do
    allow(described_class).to receive(:run_diagnostics_command).and_return(0)

    rc = described_class.main(["describe-state", "--project", "portal-dev"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_diagnostics_command).with(
      [
        "describe-state",
        "--project", "portal-dev",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "active-runs.json").to_s,
        "--worker-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "worker-runs.json").to_s
      ]
    )
  end

  it "emits selected and projected states through diagnostics" do
    Dir.mktmpdir("a3-run-describe-state-") do |temp_dir|
      root = Pathname(temp_dir)
      active_runs = root.join(".work", "a3", "state", "portal-dev", "active-runs.json")
      worker_runs = root.join(".work", "a3", "state", "portal-dev", "worker-runs.json")
      active_runs.dirname.mkpath
      active_runs.write(JSON.generate({ "active_task_refs" => ["Portal#1"] }))
      worker_runs.write(
        JSON.generate(
          {
            "runs" => {
              "Portal#1" => {
                "task_ref" => "Portal#1",
                "task_id" => 1,
                "team" => "implementation",
                "phase" => "implementation",
                "state" => "selected",
                "started_at" => "2026-03-30T00:00:00+00:00",
                "heartbeat_at" => "2026-03-30T00:00:01+00:00",
                "updated_at_epoch_ms" => 20
              },
              "Portal#2" => {
                "task_ref" => "Portal#2",
                "task_id" => 2,
                "team" => "planner",
                "phase" => nil,
                "state" => "blocked_task_failure",
                "started_at" => "2026-03-30T00:00:00+00:00",
                "heartbeat_at" => "2026-03-30T00:00:01+00:00",
                "updated_at_epoch_ms" => 10
              }
            }
          }
        )
      )
      stub_const("A3RootUtilityLauncher::ROOT_DIR", root)

      stdout = capture_stdout { expect(described_class.main(["describe-state", "--project", "portal-dev"])).to eq(0) }
      payload = JSON.parse(stdout)
      expect(payload.fetch("selected_pending_refs")).to eq(["Portal#1"])
      recent_by_ref = payload.fetch("recent_runs").to_h { |item| [item.fetch("task_ref"), item] }
      expect(recent_by_ref.fetch("Portal#2").fetch("state")).to eq("blocked_task_failure")
    end
  end

  it "uses project defaults for watch" do
    allow(described_class).to receive(:run_diagnostics_command).and_return(0)

    rc = described_class.main(["watch", "--project", "portal-dev", "--interval", "3", "--iterations", "4"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_diagnostics_command).with(
      [
        "watch",
        "--project", "portal-dev",
        "--root-dir", described_class::ROOT_DIR.to_s,
        "--active-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "active-runs.json").to_s,
        "--worker-runs-file", described_class::ROOT_DIR.join(".work", "a3", "state", "portal-dev", "worker-runs.json").to_s,
        "--interval", "3.0",
        "--iterations", "4"
      ]
    )
  end

  it "uses project launcher for doctor-env" do
    allow(described_class).to receive(:run_diagnostics_command).and_return(0)

    rc = described_class.main(["doctor-env", "--project", "portal-dev"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_diagnostics_command).with(
      [
        "doctor-env",
        "--launcher-config", described_class::CONFIG_DIR.join("portal-dev", "launcher.json").to_s
      ]
    )
  end

  it "propagates portal runtime config prepare failures for portal doctor-env" do
    allow(described_class).to receive(:run_prepare_portal_runtime_config).and_return(7)

    rc = described_class.main(["doctor-env", "--project", "portal"])

    expect(rc).to eq(7)
  end

  it "uses internally materialized runtime config for portal doctor-env" do
    allow(described_class).to receive(:run_prepare_portal_runtime_config).and_return(0)
    allow(described_class).to receive(:run_diagnostics_command).and_return(0)

    rc = described_class.main(["doctor-env", "--project", "portal"])

    expect(rc).to eq(0)
    expect(described_class).to have_received(:run_diagnostics_command).with(
      [
        "doctor-env",
        "--launcher-config", described_class::PORTAL_RUNTIME_CONFIG.to_s
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
end
