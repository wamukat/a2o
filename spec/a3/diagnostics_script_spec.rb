# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "time"
require "a3/operator/diagnostics"

RSpec.describe A3Diagnostics do
  it "describes state through the engine diagnostics operator" do
    Dir.mktmpdir("a3-diagnostics-wrapper-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      worker_runs.write(JSON.generate({ "runs" => {} }))

      stdout = capture_stdout do
        expect(
          described_class.main(
            [
              "describe-state",
              "--project", "sample",
              "--root-dir", root.to_s,
              "--active-runs-file", active_runs.to_s,
              "--worker-runs-file", worker_runs.to_s
            ]
          )
        ).to eq(0)
      end

      expect(JSON.parse(stdout).fetch("active_refs")).to eq([])
    end
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

  it "includes active and recent runs in describe-state" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      current_iso = Time.now.utc.iso8601
      active_runs.write(JSON.generate({ "active_task_refs" => ["Sample#1"] }))
      worker_runs.write(
        JSON.generate(
          "runs" => {
            "Sample#1" => {
              "task_ref" => "Sample#1",
              "task_id" => 1,
              "team" => "implementation",
              "phase" => "implementation",
              "state" => "running",
              "started_at" => current_iso,
              "heartbeat_at" => current_iso,
              "updated_at_epoch_ms" => 10
            }
          }
        )
      )

      report = described_class.describe_state(
        project: "sample",
        root_dir: root,
        active_runs_file: active_runs,
        worker_runs_file: worker_runs
      )

      expect(report.fetch("active_refs")).to eq(["Sample#1"])
      expect(report.fetch("running_runs").first.fetch("task_ref")).to eq("Sample#1")
    end
  end

  it "marks state unavailable when worker store is invalid json" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      worker_runs.write("{")

      report = described_class.describe_state(
        project: "sample",
        root_dir: root,
        active_runs_file: active_runs,
        worker_runs_file: worker_runs
      )

      expect(report.fetch("running_runs")).to eq([])
      expect(report.fetch("recent_runs")).to eq([])
      expect(report.fetch("state_unavailable")).not_to eq([])
    end
  end

  it "projects selected pending and launch_started states" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      current_iso = Time.now.utc.iso8601
      active_runs.write(JSON.generate({ "active_task_refs" => ["Sample#10", "Sample#11"] }))
      worker_runs.write(
        JSON.generate(
          "runs" => {
            "Sample#10" => {
              "task_ref" => "Sample#10", "task_id" => 10, "team" => "implementation", "phase" => "implementation",
              "state" => "selected", "started_at" => current_iso, "heartbeat_at" => current_iso, "updated_at_epoch_ms" => 30
            },
            "Sample#11" => {
              "task_ref" => "Sample#11", "task_id" => 11, "team" => "inspection", "phase" => "inspection",
              "state" => "started", "started_at" => current_iso, "heartbeat_at" => current_iso, "updated_at_epoch_ms" => 20
            }
          }
        )
      )

      report = described_class.describe_state(project: "sample", root_dir: root, active_runs_file: active_runs, worker_runs_file: worker_runs)

      expect(report.fetch("selected_pending_refs")).to eq(["Sample#10"])
      expect(report.fetch("running_runs").first.fetch("state")).to eq("launch_started")
    end
  end

  it "projects integration_judgment as merge and keeps internal phase" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      current_iso = Time.now.utc.iso8601
      active_runs.write(JSON.generate({ "active_task_refs" => ["Sample#20"] }))
      worker_runs.write(
        JSON.generate(
          "runs" => {
            "Sample#20::integration_judgment::integration_judgment" => {
              "task_ref" => "Sample#20", "task_id" => 20, "team" => "review", "phase" => "integration_judgment",
              "state" => "running_command", "started_at" => current_iso, "heartbeat_at" => current_iso, "updated_at_epoch_ms" => 20
            }
          }
        )
      )

      report = described_class.describe_state(project: "sample", root_dir: root, active_runs_file: active_runs, worker_runs_file: worker_runs)
      running = report.fetch("running_runs").first
      expect(running.fetch("phase")).to eq("merge")
      expect(running.fetch("internal_phase")).to eq("integration_judgment")
    end
  end

  it "inspects runtime env and supports generic AI CLI vendor rg fallback" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      vendor_rg = root.join(".ai-cli", "vendor", "ripgrep", "rg")
      vendor_rg.dirname.mkpath
      vendor_rg.write("#!/bin/sh\n")
      File.chmod(0o755, vendor_rg)

      report = described_class.inspect_runtime_env(
        { "required_bins" => ["rg"], "allow_executor_vendor_rg_fallback" => true },
        { "inherit_env" => true, "env_files" => [], "env_overrides" => {} },
        env: { "HOME" => root.to_s, "PATH" => "" }
      )

      expect(report.fetch("missing_bins")).to eq([])
      expect(report.fetch("resolved_bins").fetch("rg")).to eq(vendor_rg.to_s)
    end
  end

  it "reports doctor-env with env file existence" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      launcher = root.join("launcher.json")
      env_file = root.join("sample.env")
      env_file.write("TOKEN=test\n")
      launcher.write(
        JSON.pretty_generate(
          "scheduler" => { "backend" => "launchd" },
          "kanban" => { "backend" => "subprocess-cli" },
          "shell" => { "env_files" => [env_file.to_s], "env_overrides" => {}, "inherit_env" => false },
          "runtime_env" => { "required_bins" => [], "allow_executor_vendor_rg_fallback" => false }
        )
      )

      report = described_class.doctor_env(launcher_config_path: launcher)
      expect(report.fetch("shell").fetch("env_files")).to eq([{ "path" => env_file.to_s, "exists" => true }])
    end
  end
end
