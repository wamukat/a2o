# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "a3/operator/reconcile"

RSpec.describe A3Reconcile do
  it "inspects active runs through the engine reconcile operator" do
    Dir.mktmpdir("a3-reconcile-wrapper-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      worker_runs.write(JSON.generate({ "runs" => {} }))

      stdout = capture_stdout do
        expect(
          described_class.main(
            [
              "--project", "sample",
              "--active-runs-file", active_runs.to_s,
              "--worker-runs-file", worker_runs.to_s,
              "--live-process-pattern", "unlikely-a3-test-process-pattern"
            ]
          )
        ).to eq(0)
      end

      expect(JSON.parse(stdout).fetch("active_refs_before")).to eq([])
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

  it "flags terminal and missing runs as stale" do
    Dir.mktmpdir("a3-reconcile-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => ["Sample#1", "Sample#2"] }))
      worker_runs.write(
        JSON.generate(
          "runs" => {
            "Sample#1" => {
              "task_ref" => "Sample#1", "task_id" => 1, "team" => "implementation", "phase" => "implementation",
              "state" => "completed", "started_at" => "2026-03-23T00:00:00+00:00", "heartbeat_at" => "2026-03-23T00:00:01+00:00",
              "updated_at_epoch_ms" => 1
            }
          }
        )
      )
      allow(described_class).to receive(:live_scheduler_processes).and_return([])

      payload = described_class.inspect_stale_active_runs(project: "sample", active_runs_file: active_runs, worker_runs_file: worker_runs)
      reasons = payload.fetch("stale_active_runs").each_with_object({}) { |item, acc| acc[item.fetch("task_ref")] = item.fetch("reason") }
      ids = payload.fetch("stale_active_runs").each_with_object({}) { |item, acc| acc[item.fetch("task_ref")] = item["task_id"] }

      expect(reasons["Sample#1"]).to eq("latest_run_terminal")
      expect(reasons["Sample#2"]).to eq("missing_worker_run")
      expect(ids["Sample#1"]).to eq(1)
      expect(ids["Sample#2"]).to be_nil
      expect(payload.fetch("active_refs_after")).to eq([])
    end
  end

  it "clears stale nonterminal runs when no live process exists" do
    Dir.mktmpdir("a3-reconcile-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => ["Sample#9"] }))
      worker_runs.write(
        JSON.generate(
          "runs" => {
            "Sample#9" => {
              "task_ref" => "Sample#9", "task_id" => 9, "team" => "implementation", "phase" => "implementation",
              "state" => "running", "started_at" => "2026-03-23T00:00:00+00:00", "heartbeat_at" => "2026-03-23T00:10:00+00:00",
              "updated_at_epoch_ms" => 10
            }
          }
        )
      )
      allow(described_class).to receive(:live_scheduler_processes).and_return([])

      payload = described_class.apply_stale_active_run_reconciliation(project: "sample", active_runs_file: active_runs, worker_runs_file: worker_runs)

      expect(payload.fetch("applied")).to eq(true)
      expect(payload.fetch("stale_active_runs").map { |item| item.fetch("task_ref") }).to eq(["Sample#9"])
      expect(JSON.parse(active_runs.read)).to eq({ "active_task_refs" => [] })
      worker_payload = JSON.parse(worker_runs.read)
      expect(worker_payload.fetch("runs").fetch("Sample#9").fetch("state")).to eq("failed")
      expect(worker_payload.fetch("runs").fetch("Sample#9").fetch("detail")).to include("reconciled_stale_run(reason=stale_worker_run)")
    end
  end

  it "flags worker run without active ref as stale" do
    Dir.mktmpdir("a3-reconcile-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      active_runs.write(JSON.generate({ "active_task_refs" => [] }))
      worker_runs.write(
        JSON.generate(
          "runs" => {
            "Sample#2561" => {
              "task_ref" => "Sample#2561", "task_id" => 2561, "team" => "implementation", "phase" => "implementation",
              "state" => "running", "started_at" => "2026-03-23T00:00:00+00:00", "heartbeat_at" => "2026-03-23T00:10:00+00:00",
              "updated_at_epoch_ms" => 10
            }
          }
        )
      )
      allow(described_class).to receive(:live_scheduler_processes).and_return([])

      payload = described_class.inspect_stale_active_runs(project: "sample", active_runs_file: active_runs, worker_runs_file: worker_runs)
      expect(payload.fetch("stale_active_runs")).to eq([
        { "task_ref" => "Sample#2561", "task_id" => 2561, "reason" => "stale_worker_run", "latest_state" => "running" }
      ])
    end
  end

  it "applies status reset with runtime env" do
    Dir.mktmpdir("a3-reconcile-") do |dir|
      root = Pathname(dir)
      launcher_config = root.join("launcher.json")
      env_file = root.join("sample.env")
      env_file.write("KANBAN_API_TOKEN=test-token\nPATH=/usr/bin:/bin\n")
      launcher_config.write(
        JSON.pretty_generate(
          "executor" => { "kind" => "ai-cli", "implementation" => "openai-codex" },
          "scheduler" => { "backend" => "manual", "job_name" => "dev.a3.sample.watch", "command_argv" => ["/bin/sh", "-lc", "true"] },
          "runtime_env" => { "required_bins" => [], "path_entries" => [] },
          "shell" => { "executable" => "/bin/sh", "login" => false, "interactive" => false, "inherit_env" => false, "env_files" => [env_file.to_s], "env_overrides" => { "JAVA_HOME" => "/opt/jdk-25" } },
          "kanban" => { "backend" => "subprocess-cli", "command_argv" => ["task", "kanban:api", "--"], "working_directory" => root.to_s }
        )
      )

      received = nil
      allow(described_class).to receive(:system) do |env, *argv, **kwargs|
        received = { env: env, argv: argv, kwargs: kwargs }
        true
      end

      described_class.apply_status_reset(launcher_config: launcher_config, task_ref: "Sample#2561", task_id: 2561, status: "To do")

      expect(received[:argv]).to eq(["task", "kanban:api", "--", "task-transition", "--task-id", "2561", "--status", "To do"])
      expect(received[:kwargs][:chdir]).to eq(root.to_s)
      expect(received[:env]["KANBAN_API_TOKEN"]).to eq("test-token")
      expect(received[:env]["JAVA_HOME"]).to eq("/opt/jdk-25")
    end
  end

  it "resolves generic AI CLI vendor rg when allowed" do
    Dir.mktmpdir("a3-reconcile-") do |dir|
      root = Pathname(dir)
      launcher_config = root.join("launcher.json")
      env_file = root.join("sample.env")
      ai_cli_home = root.join(".ai-cli-home")
      vendor_dir = ai_cli_home.join("vendor", "ripgrep")
      vendor_dir.mkpath
      vendor_rg = vendor_dir.join("rg")
      vendor_rg.write("#!/bin/sh\nexit 0\n")
      File.chmod(0o755, vendor_rg)
      env_file.write("AI_CLI_HOME=#{ai_cli_home}\nPATH=/usr/bin:/bin\n")
      launcher_config.write(
        JSON.pretty_generate(
          "runtime_env" => { "required_bins" => ["rg"], "path_entries" => [], "allow_executor_vendor_rg_fallback" => true },
          "shell" => { "inherit_env" => false, "env_files" => [env_file.to_s], "env_overrides" => {} },
          "kanban" => { "backend" => "subprocess-cli", "command_argv" => ["task", "kanban:api", "--"], "working_directory" => root.to_s }
        )
      )

      received = nil
      allow(described_class).to receive(:system) do |env, *_argv, **_kwargs|
        received = env
        true
      end

      described_class.apply_status_reset(launcher_config: launcher_config, task_ref: "Sample#2561", task_id: 2561, status: "To do")
      expect(received.fetch("PATH").split(":").first).to eq(vendor_dir.to_s)
    end
  end


  it "ignores unrelated AI executor processes when checking scheduler liveness" do
    allow(IO).to receive(:popen).and_return("ai-runner --json -\n")

    expect(described_class.live_scheduler_processes("a2o-reference")).to eq([])
  end

  it "recognizes current scheduler shot processes" do
    allow(IO).to receive(:popen).and_return(<<~PS)
      a2o-runtime-run-once
      ruby -I a3-engine/lib a3-engine/bin/a3 execute-until-idle --storage-dir .work/a3/a2o-reference-kanban-scheduler-auto reference-products/multi-repo-fixture/project-package/manifest.yml
    PS

    matches = described_class.live_scheduler_processes(
      "a2o-reference",
      patterns: ["a2o-runtime-run-once", "a2o-reference-kanban-scheduler-auto"]
    )
    expect(matches).to eq(
      [
        "a2o-runtime-run-once",
        "ruby -I a3-engine/lib a3-engine/bin/a3 execute-until-idle --storage-dir .work/a3/a2o-reference-kanban-scheduler-auto reference-products/multi-repo-fixture/project-package/manifest.yml"
      ]
    )
  end
end
