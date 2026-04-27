# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "time"
require "a3/operator/diagnostics"

RSpec.describe A3Diagnostics do
  def write_agent_job(path, job_id:, task_ref:, phase:, state:, heartbeat_at:, activity_state: nil)
    payload = path.exist? ? JSON.parse(path.read) : {}
    payload[job_id] = {
      "state" => state == "selected" ? "queued" : (state == "completed" ? "completed" : "claimed"),
      "claimed_at" => heartbeat_at,
      "heartbeat_at" => heartbeat_at,
      "request" => {
        "job_id" => job_id,
        "task_ref" => task_ref,
        "phase" => phase,
        "command" => "worker",
        "args" => [],
        "working_dir" => path.dirname.to_s
      },
      "result" => activity_state || state == "completed" ? { "status" => "succeeded", "activity_state" => activity_state }.compact : nil
    }.compact
    path.write(JSON.generate(payload))
  end

  it "describes state through the engine diagnostics operator" do
    Dir.mktmpdir("a3-diagnostics-wrapper-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      agent_jobs = root.join("custom_jobs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      worker_runs.write(JSON.generate({ "runs" => {} }))
      write_agent_job(agent_jobs, job_id: "job-1", task_ref: "Sample#1", phase: "implementation", state: "running_command", heartbeat_at: Time.now.utc.iso8601)

      stdout = capture_stdout do
        expect(
          described_class.main(
            [
              "describe-state",
              "--project", "sample",
              "--root-dir", root.to_s,
              "--active-runs-file", active_runs.to_s,
              "--agent-jobs-file", agent_jobs.to_s
            ]
          )
        ).to eq(0)
      end

      payload = JSON.parse(stdout)
      expect(payload.fetch("active_refs")).to eq([])
      expect(payload.fetch("recent_runs").map { |item| item.fetch("task_ref") }).to include("Sample#1")
      expect(payload.fetch("agent_jobs_file")).to eq(agent_jobs.to_s)
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
      write_agent_job(root.join("agent_jobs.json"), job_id: "job-1", task_ref: "Sample#1", phase: "implementation", state: "running", heartbeat_at: current_iso)

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
      root.join("agent_jobs.json").write("{")

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
      write_agent_job(root.join("agent_jobs.json"), job_id: "job-10", task_ref: "Sample#10", phase: "implementation", state: "selected", heartbeat_at: current_iso, activity_state: "selected")
      write_agent_job(root.join("agent_jobs.json"), job_id: "job-11", task_ref: "Sample#11", phase: "inspection", state: "started", heartbeat_at: current_iso, activity_state: "started")

      report = described_class.describe_state(project: "sample", root_dir: root, active_runs_file: active_runs, worker_runs_file: worker_runs)

      expect(report.fetch("selected_pending_refs")).to eq(["Sample#10"])
      expect(report.fetch("running_runs").first.fetch("state")).to eq("launch_started")
    end
  end

  it "treats queued agent jobs as selected pending but not running" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      root.join("agent_jobs.json").write(
        JSON.generate(
          "job-30" => {
            "state" => "queued",
            "request" => {
              "job_id" => "job-30",
              "task_ref" => "Sample#30",
              "phase" => "implementation",
              "command" => "worker",
              "args" => [],
              "working_dir" => root.to_s
            }
          }
        )
      )

      report = described_class.describe_state(project: "sample", root_dir: root, active_runs_file: active_runs, worker_runs_file: worker_runs)

      expect(report.fetch("selected_pending_refs")).to eq(["Sample#30"])
      expect(report.fetch("running_runs")).to eq([])
    end
  end

  it "treats succeeded completed agent jobs as terminal" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      current_iso = Time.now.utc.iso8601
      active_runs.write(JSON.generate({ "active_task_refs" => ["Sample#31"] }))
      write_agent_job(root.join("agent_jobs.json"), job_id: "job-31", task_ref: "Sample#31", phase: "implementation", state: "completed", heartbeat_at: current_iso)

      report = described_class.describe_state(project: "sample", root_dir: root, active_runs_file: active_runs, worker_runs_file: worker_runs)

      expect(report.fetch("running_runs")).to eq([])
      expect(report.fetch("recent_runs").first.fetch("state")).to eq("completed")
    end
  end

  it "treats cancelled and stale completed agent jobs as terminal" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      now = Time.now.utc.iso8601
      active_runs.write(JSON.generate({ "active_task_refs" => %w[Sample#32 Sample#33] }))
      agent_jobs = root.join("agent_jobs.json")
      write_agent_job(agent_jobs, job_id: "job-32", task_ref: "Sample#32", phase: "implementation", state: "completed", heartbeat_at: now)
      payload = JSON.parse(agent_jobs.read)
      payload.fetch("job-32").fetch("result")["status"] = "cancelled"
      payload["job-33"] = payload.fetch("job-32").merge(
        "request" => payload.fetch("job-32").fetch("request").merge("job_id" => "job-33", "task_ref" => "Sample#33"),
        "result" => payload.fetch("job-32").fetch("result").merge("status" => "stale")
      )
      agent_jobs.write(JSON.generate(payload))

      report = described_class.describe_state(project: "sample", root_dir: root, active_runs_file: active_runs, worker_runs_file: worker_runs)

      expect(report.fetch("running_runs")).to eq([])
      states = report.fetch("recent_runs").to_h { |item| [item.fetch("task_ref"), item.fetch("state")] }
      expect(states).to include("Sample#32" => "cancelled", "Sample#33" => "stale")
    end
  end

  it "projects integration_judgment as merge and keeps internal phase" do
    Dir.mktmpdir("a3-diagnostics-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      current_iso = Time.now.utc.iso8601
      active_runs.write(JSON.generate({ "active_task_refs" => ["Sample#20"] }))
      write_agent_job(root.join("agent_jobs.json"), job_id: "job-20", task_ref: "Sample#20", phase: "integration_judgment", state: "running_command", heartbeat_at: current_iso)

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
