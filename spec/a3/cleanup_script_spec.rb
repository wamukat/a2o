# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "a3/operator/cleanup"

RSpec.describe A3Cleanup do
  it "applies launcher env files when loading task snapshots" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      env_file = root.join(".work", "a3", "env", "sample-launchd.env")
      launcher = root.join(".work", "a3", "config", "sample-launchd.json")
      FileUtils.mkdir_p(env_file.dirname)
      FileUtils.mkdir_p(launcher.dirname)
      File.write(env_file, "KANBAN_API_TOKEN=test-token\n")
      File.write(launcher, JSON.generate({ "shell" => { "env_files" => [env_file.to_s], "env_overrides" => { "FOO" => "bar" } } }))

      captured_env = nil
      allow(Open3).to receive(:capture3) do |env, *_args, **_kwargs|
        captured_env = env
        ['[{"ref":"Sample#1","status":"Done","labels":[]}]', "", instance_double(Process::Status, success?: true)]
      end

      snapshots = described_class.load_task_snapshots(root_dir: root, project: "sample", launcher_config: launcher)

      expect(snapshots).to eq([{ "ref" => "Sample#1", "status" => "Done", "labels" => [] }])
      expect(captured_env["KANBAN_API_TOKEN"]).to eq("test-token")
      expect(captured_env["FOO"]).to eq("bar")
    end
  end

  it "fails when launcher env file is missing" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      launcher = root.join(".work", "a3", "config", "sample-launchd.json")
      FileUtils.mkdir_p(launcher.dirname)
      File.write(launcher, JSON.generate({ "shell" => { "env_files" => [root.join("missing.env").to_s], "env_overrides" => {} } }))

      expect do
        described_class.load_task_snapshots(root_dir: root, project: "sample", launcher_config: launcher)
      end.to raise_error(RuntimeError, /env file could not be read/)
    end
  end

  it "parses env files with scheduler-style quoting rules" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      env_file = root.join("sample.env")
      File.write(env_file, "export TOKEN=\"abc def\"\nHASH=abc#123\nCOMMENTED=value # inline comment\n")

      payload = described_class.parse_env_file(root_dir: root, env_file: env_file)

      expect(payload["TOKEN"]).to eq("abc def")
      expect(payload["HASH"]).to eq("abc#123")
      expect(payload["COMMENTED"]).to eq("value")
    end
  end

  it "selects done artifacts older than ttl" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      issue_dir = root.join(".work", "a3", "issues", "sample", "sample-123")
      runtime_dir = root.join(".work", "a3", "runtime", "inspection", "sample", "sample-123")
      result_file = root.join(".work", "a3", "results", "sample", "20260322T000000Z-Sample-123.json")
      log_dir = root.join(".work", "a3", "results", "logs", "sample", "Sample-123")
      [issue_dir, runtime_dir, log_dir].each { |path| FileUtils.mkdir_p(path) }
      FileUtils.mkdir_p(result_file.dirname)
      File.write(result_file, "{}")
      old = Time.now.utc - (30 * 3600)
      [issue_dir, runtime_dir, result_file, log_dir].each { |path| File.utime(old, old, path) }

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [{ "ref" => "Sample#123", "status" => "Done", "labels" => [] }],
        active_refs: Set.new,
        now: Time.now.utc,
        done_ttl_hours: 24,
        blocked_ttl_hours: 24,
        result_ttl_hours: 168,
        log_ttl_hours: 168,
        quarantine_ttl_hours: 168,
        cache_ttl_hours: 168
      )

      expect(candidates.length).to eq(2)
      expect(candidates.map(&:task_ref).uniq).to eq(["Sample#123"])
      expect(candidates.map(&:kind).to_set).to eq(Set["issue_workspace", "runtime_workspace"])
    end
  end

  it "selects orphan artifacts older than ttl" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      issue_dir = root.join(".work", "a3", "issues", "sample", "sample-555")
      runtime_dir = root.join(".work", "a3", "runtime", "inspection", "sample", "sample-555")
      result_file = root.join(".work", "a3", "results", "sample", "20260322T000000Z-Sample-555.json")
      log_dir = root.join(".work", "a3", "results", "logs", "sample", "Sample-555")
      [issue_dir, runtime_dir, log_dir].each { |path| FileUtils.mkdir_p(path) }
      FileUtils.mkdir_p(result_file.dirname)
      File.write(result_file, "{}")
      old = Time.now.utc - (30 * 3600)
      [issue_dir, runtime_dir, result_file, log_dir].each { |path| File.utime(old, old, path) }

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [],
        active_refs: Set.new,
        now: Time.now.utc,
        done_ttl_hours: 24,
        blocked_ttl_hours: 24,
        result_ttl_hours: 24,
        log_ttl_hours: 24,
        quarantine_ttl_hours: 24,
        cache_ttl_hours: 24
      )

      expect(candidates.length).to eq(4)
      expect(candidates.map(&:task_ref).uniq).to eq([nil])
      expect(candidates.map(&:kind).to_set).to eq(Set["issue_workspace", "runtime_workspace", "result_file", "log_dir"])
    end
  end

  it "ignores quarantine root when collecting orphan paths" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      FileUtils.mkdir_p(root.join(".work", "a3", "quarantine", "sample", "sample-2700", "20260328T000000Z"))

      paths = described_class.collect_orphan_paths(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        known_task_refs: Set.new,
        active_refs: Set.new
      )

      expect(paths).to eq([])
    end
  end

  it "skips active tasks" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      issue_dir = root.join(".work", "a3", "issues", "sample", "sample-123")
      FileUtils.mkdir_p(issue_dir)

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [{ "ref" => "Sample#123", "status" => "Done", "labels" => [] }],
        active_refs: Set["Sample#123"],
        now: Time.now.utc,
        done_ttl_hours: 24,
        blocked_ttl_hours: 24,
        result_ttl_hours: 168,
        log_ttl_hours: 168,
        quarantine_ttl_hours: 168,
        cache_ttl_hours: 168
      )

      expect(candidates).to eq([])
    end
  end

  it "keeps result and logs until evidence ttl" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      result_file = root.join(".work", "a3", "results", "sample", "20260322T000000Z-Sample-123.json")
      log_dir = root.join(".work", "a3", "results", "logs", "sample", "Sample-123")
      FileUtils.mkdir_p(result_file.dirname)
      FileUtils.mkdir_p(log_dir)
      File.write(result_file, "{}")
      old = Time.now.utc - (30 * 3600)
      File.utime(old, old, result_file)
      File.utime(old, old, log_dir)

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [{ "ref" => "Sample#123", "status" => "Done", "labels" => [] }],
        active_refs: Set.new,
        now: Time.now.utc,
        done_ttl_hours: 24,
        blocked_ttl_hours: 24,
        result_ttl_hours: 168,
        log_ttl_hours: 168,
        quarantine_ttl_hours: 168,
        cache_ttl_hours: 168
      )

      expect(candidates).to eq([])
    end
  end

  it "applies cleanup candidates" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      issue_dir = root.join(".work", "a3", "issues", "sample", "sample-123")
      FileUtils.mkdir_p(issue_dir)

      removed = described_class.apply_cleanup_candidates(
        [described_class::CleanupCandidate.new(kind: "directory", path: issue_dir.to_s, reason: "done_ttl>24h", task_ref: "Sample#123")]
      )

      expect(removed.length).to eq(1)
      expect(issue_dir).not_to exist
    end
  end

  it "includes nonterminal worker runs in active refs" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      File.write(active_runs, JSON.generate({ "active_task_refs" => ["Sample#1"] }))
      File.write(root.join("agent_jobs.json"), JSON.generate({
        "job-2" => { "state" => "claimed", "claimed_at" => Time.now.utc.iso8601, "heartbeat_at" => Time.now.utc.iso8601, "request" => { "job_id" => "job-2", "task_ref" => "Sample#2", "phase" => "implementation" } },
        "job-3" => { "state" => "completed", "claimed_at" => Time.now.utc.iso8601, "heartbeat_at" => Time.now.utc.iso8601, "request" => { "job_id" => "job-3", "task_ref" => "Sample#3", "phase" => "implementation" }, "result" => { "status" => "succeeded" } }
      }))

      refs = described_class.load_active_refs(active_runs_file: active_runs, worker_runs_file: worker_runs)

      expect(refs).to eq(Set["Sample#1", "Sample#2"])
    end
  end

  it "selects only runtime dirs for inactive targeted cleanup" do
    Dir.mktmpdir("a3-cleanup-targeted-") do |dir|
      root = Pathname(dir)
      issue_dir = root.join(".work", "a3", "issues", "sample", "sample-123")
      runtime_dir = root.join(".work", "a3", "runtime", "inspection", "sample", "sample-123")
      FileUtils.mkdir_p(issue_dir)
      FileUtils.mkdir_p(runtime_dir)

      candidates = described_class.build_targeted_runtime_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_refs: ["Sample#123", "Sample#124"],
        active_refs: Set.new
      )

      expect(candidates.length).to eq(1)
      expect(candidates.first.kind).to eq("runtime_workspace")
      expect(candidates.first.task_ref).to eq("Sample#123")
      expect(candidates.first.path).to eq(runtime_dir.to_s)
    end
  end

  it "skips active refs during targeted cleanup" do
    Dir.mktmpdir("a3-cleanup-targeted-") do |dir|
      root = Pathname(dir)
      runtime_dir = root.join(".work", "a3", "runtime", "inspection", "sample", "sample-123")
      FileUtils.mkdir_p(runtime_dir)
      active_runs = root.join("active-runs.json")
      worker_runs = root.join("worker-runs.json")
      File.write(active_runs, JSON.generate({ "active_task_refs" => ["Sample#123"] }))
      File.write(worker_runs, JSON.generate({ "runs" => {} }))

      removed = described_class.apply_targeted_runtime_cleanup(
        root_dir: root,
        project: "sample",
        task_refs: ["Sample#123"],
        active_runs_file: active_runs,
        worker_runs_file: worker_runs
      )

      expect(removed).to eq([])
      expect(runtime_dir).to exist
    end
  end

  it "uses kanban project ref for sample-test orphans and active refs" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      issue_dir = root.join(".work", "a3", "issues", "sample-test", "sample-555")
      runtime_dir = root.join(".work", "a3", "runtime", "inspection", "sample-test", "sample-555")
      result_file = root.join(".work", "a3", "results", "sample-test", "20260322T000000Z-Sample-555.json")
      log_dir = root.join(".work", "a3", "results", "logs", "sample-test", "Sample-555")
      [issue_dir, runtime_dir, log_dir].each { |path| FileUtils.mkdir_p(path) }
      FileUtils.mkdir_p(result_file.dirname)
      File.write(result_file, "{}")
      old = Time.now.utc - (30 * 3600)
      [issue_dir, runtime_dir, result_file, log_dir].each { |path| File.utime(old, old, path) }

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample-test",
        task_project_ref: "Sample",
        task_snapshots: [],
        active_refs: Set.new,
        now: Time.now.utc,
        done_ttl_hours: 24,
        blocked_ttl_hours: 24,
        result_ttl_hours: 24,
        log_ttl_hours: 24,
        quarantine_ttl_hours: 24,
        cache_ttl_hours: 24
      )

      expect(candidates.length).to eq(4)

      kept = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample-test",
        task_project_ref: "Sample",
        task_snapshots: [],
        active_refs: Set["Sample#555"],
        now: Time.now.utc,
        done_ttl_hours: 24,
        blocked_ttl_hours: 24,
        result_ttl_hours: 24,
        log_ttl_hours: 24,
        quarantine_ttl_hours: 24,
        cache_ttl_hours: 24
      )

      expect(kept).to eq([])
    end
  end

  it "selects current scheduler quarantine workspaces older than ttl" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      quarantine_dir = root.join(".work", "a3", "sample-kanban-scheduler-auto", "quarantine", "Sample-3238")
      FileUtils.mkdir_p(quarantine_dir)
      old = Time.now.utc - (200 * 3600)
      File.utime(old, old, quarantine_dir)

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [{ "ref" => "Sample#3238", "status" => "Done", "labels" => [] }],
        active_refs: Set.new,
        now: Time.now.utc,
        done_ttl_hours: 24,
        blocked_ttl_hours: 24,
        result_ttl_hours: 168,
        log_ttl_hours: 168,
        quarantine_ttl_hours: 168,
        cache_ttl_hours: 168
      )

      expect(candidates.map(&:kind)).to include("quarantine_workspace")
      expect(candidates.map(&:task_ref)).to include("Sample#3238")
    end
  end

  it "selects disposable cache directories older than ttl" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      cache_dir = root.join(".work", "cache", "m2-seed")
      FileUtils.mkdir_p(cache_dir)
      old = Time.now.utc - (200 * 3600)
      File.utime(old, old, cache_dir)

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [],
        active_refs: Set.new,
        now: Time.now.utc,
        done_ttl_hours: 24,
        blocked_ttl_hours: 24,
        result_ttl_hours: 168,
        log_ttl_hours: 168,
        quarantine_ttl_hours: 168,
        cache_ttl_hours: 168
      )

      expect(candidates.map(&:kind)).to include("cache_dir")
      expect(candidates.map(&:path)).to include(cache_dir.to_s)
    end
  end

  it "selects quarantine surplus beyond count budget" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      older = root.join(".work", "a3", "sample-kanban-scheduler-auto", "quarantine", "Sample-3231")
      newer = root.join(".work", "a3", "sample-kanban-scheduler-auto", "quarantine", "Sample-3238")
      [older, newer].each { |path| FileUtils.mkdir_p(path) }
      now = Time.now.utc
      File.utime(now - 3600, now - 3600, older)
      File.utime(now, now, newer)

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [
          { "ref" => "Sample#3231", "status" => "Done", "labels" => [] },
          { "ref" => "Sample#3238", "status" => "Done", "labels" => [] }
        ],
        active_refs: Set.new,
        now: now,
        done_ttl_hours: 999,
        blocked_ttl_hours: 999,
        result_ttl_hours: 999,
        log_ttl_hours: 999,
        quarantine_ttl_hours: 999,
        cache_ttl_hours: 999,
        max_quarantine_count: 1,
        max_result_count: nil,
        max_log_count: nil
      )

      expect(candidates.map(&:reason)).to include("quarantine_count>1")
      expect(candidates.map(&:task_ref)).to include("Sample#3231")
      expect(candidates.map(&:task_ref)).not_to include("Sample#3238")
    end
  end

  it "selects result and log surplus beyond count budgets" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      result_older = root.join(".work", "a3", "results", "sample", "20260322T000000Z-Sample-3231.json")
      result_newer = root.join(".work", "a3", "results", "sample", "20260323T000000Z-Sample-3238.json")
      log_older = root.join(".work", "a3", "results", "logs", "sample", "Sample-3231")
      log_newer = root.join(".work", "a3", "results", "logs", "sample", "Sample-3238")
      FileUtils.mkdir_p(result_older.dirname)
      FileUtils.mkdir_p(log_older.dirname)
      File.write(result_older, "{}")
      File.write(result_newer, "{}")
      FileUtils.mkdir_p(log_older)
      FileUtils.mkdir_p(log_newer)
      now = Time.now.utc
      [result_older, log_older].each { |path| File.utime(now - 3600, now - 3600, path) }
      [result_newer, log_newer].each { |path| File.utime(now, now, path) }

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [
          { "ref" => "Sample#3231", "status" => "Done", "labels" => [] },
          { "ref" => "Sample#3238", "status" => "Done", "labels" => [] }
        ],
        active_refs: Set.new,
        now: now,
        done_ttl_hours: 999,
        blocked_ttl_hours: 999,
        result_ttl_hours: 999,
        log_ttl_hours: 999,
        quarantine_ttl_hours: 999,
        cache_ttl_hours: 999,
        max_quarantine_count: nil,
        max_result_count: 1,
        max_log_count: 1
      )

      expect(candidates.map(&:reason)).to include("result_count>1")
      expect(candidates.map(&:reason)).to include("log_count>1")
      expect(candidates.select { |item| item.reason == "result_count>1" }.map(&:task_ref)).to eq(["Sample#3231"])
      expect(candidates.select { |item| item.reason == "log_count>1" }.map(&:task_ref)).to eq(["Sample#3231"])
    end
  end

  it "selects quarantine/result/log surplus beyond size budgets" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      quarantine_older = root.join(".work", "a3", "sample-kanban-scheduler-auto", "quarantine", "Sample-3231")
      quarantine_newer = root.join(".work", "a3", "sample-kanban-scheduler-auto", "quarantine", "Sample-3238")
      result_older = root.join(".work", "a3", "results", "sample", "20260322T000000Z-Sample-3231.json")
      result_newer = root.join(".work", "a3", "results", "sample", "20260323T000000Z-Sample-3238.json")
      log_older = root.join(".work", "a3", "results", "logs", "sample", "Sample-3231")
      log_newer = root.join(".work", "a3", "results", "logs", "sample", "Sample-3238")
      [quarantine_older, quarantine_newer, log_older, log_newer].each { |path| FileUtils.mkdir_p(path) }
      FileUtils.mkdir_p(result_older.dirname)
      File.write(quarantine_older.join("payload.txt"), "x" * 16)
      File.write(quarantine_newer.join("payload.txt"), "x" * 16)
      File.write(result_older, "x" * 16)
      File.write(result_newer, "x" * 16)
      File.write(log_older.join("payload.txt"), "x" * 16)
      File.write(log_newer.join("payload.txt"), "x" * 16)
      now = Time.now.utc
      [quarantine_older, result_older, log_older].each { |path| File.utime(now - 3600, now - 3600, path) }
      [quarantine_newer, result_newer, log_newer].each { |path| File.utime(now, now, path) }

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [
          { "ref" => "Sample#3231", "status" => "Done", "labels" => [] },
          { "ref" => "Sample#3238", "status" => "Done", "labels" => [] }
        ],
        active_refs: Set.new,
        now: now,
        done_ttl_hours: 999,
        blocked_ttl_hours: 999,
        result_ttl_hours: 999,
        log_ttl_hours: 999,
        quarantine_ttl_hours: 999,
        cache_ttl_hours: 999,
        max_quarantine_count: nil,
        max_result_count: nil,
        max_log_count: nil,
        max_quarantine_bytes: 20,
        max_result_bytes: 20,
        max_log_bytes: 20,
        max_cache_bytes: nil
      )

      expect(candidates.map(&:reason)).to include("quarantine_bytes>20")
      expect(candidates.map(&:reason)).to include("result_bytes>20")
      expect(candidates.map(&:reason)).to include("log_bytes>20")
      expect(candidates.select { |item| item.reason == "quarantine_bytes>20" }.map(&:task_ref)).to eq(["Sample#3231"])
      expect(candidates.select { |item| item.reason == "result_bytes>20" }.map(&:task_ref)).to eq(["Sample#3231"])
      expect(candidates.select { |item| item.reason == "log_bytes>20" }.map(&:task_ref)).to eq(["Sample#3231"])
    end
  end

  it "selects disposable cache surplus beyond size budget" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      cache_dir = root.join(".work", "cache", "m2-seed")
      FileUtils.mkdir_p(cache_dir)
      File.write(cache_dir.join("payload.txt"), "x" * 16)

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [],
        active_refs: Set.new,
        now: Time.now.utc,
        done_ttl_hours: 999,
        blocked_ttl_hours: 999,
        result_ttl_hours: 999,
        log_ttl_hours: 999,
        quarantine_ttl_hours: 999,
        cache_ttl_hours: 999,
        max_quarantine_count: nil,
        max_result_count: nil,
        max_log_count: nil,
        max_quarantine_bytes: nil,
        max_result_bytes: nil,
        max_log_bytes: nil,
        max_cache_bytes: 10
      )

      expect(candidates.map(&:reason)).to include("cache_bytes>10")
      expect(candidates.map(&:kind)).to include("cache_dir")
    end
  end

  it "selects quarantined build outputs older than ttl" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      output_dir = root.join(".work", "a3", "sample-kanban-scheduler-auto", "quarantine", "Sample-3238", "runtime_workspace", "repo-alpha", "target")
      FileUtils.mkdir_p(output_dir)
      old = Time.now.utc - (200 * 3600)
      File.utime(old, old, output_dir)

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [{ "ref" => "Sample#3238", "status" => "Done", "labels" => [] }],
        active_refs: Set.new,
        now: Time.now.utc,
        done_ttl_hours: 999,
        blocked_ttl_hours: 999,
        result_ttl_hours: 999,
        log_ttl_hours: 999,
        quarantine_ttl_hours: 999,
        cache_ttl_hours: 999,
        build_output_ttl_hours: 168,
        max_quarantine_count: nil,
        max_result_count: nil,
        max_log_count: nil,
        max_quarantine_bytes: nil,
        max_result_bytes: nil,
        max_log_bytes: nil,
        max_cache_bytes: nil,
        max_build_output_bytes: nil
      )

      expect(candidates.map(&:kind)).to include("build_output_dir")
      expect(candidates.map(&:reason)).to include("build_output_ttl>168h")
      expect(candidates.map(&:task_ref)).to include("Sample#3238")
    end
  end

  it "selects quarantined build outputs beyond size budget" do
    Dir.mktmpdir("a3-cleanup-") do |dir|
      root = Pathname(dir)
      older = root.join(".work", "a3", "sample-kanban-scheduler-auto", "quarantine", "Sample-3231", "runtime_workspace", "repo-alpha", "target")
      newer = root.join(".work", "a3", "sample-kanban-scheduler-auto", "quarantine", "Sample-3238", "runtime_workspace", "repo-alpha", "target")
      [older, newer].each { |path| FileUtils.mkdir_p(path) }
      File.write(older.join("payload.txt"), "x" * 16)
      File.write(newer.join("payload.txt"), "x" * 16)
      now = Time.now.utc
      File.utime(now - 3600, now - 3600, older)
      File.utime(now, now, newer)

      candidates = described_class.build_cleanup_candidates(
        root_dir: root,
        project: "sample",
        task_project_ref: nil,
        task_snapshots: [
          { "ref" => "Sample#3231", "status" => "Done", "labels" => [] },
          { "ref" => "Sample#3238", "status" => "Done", "labels" => [] }
        ],
        active_refs: Set.new,
        now: now,
        done_ttl_hours: 999,
        blocked_ttl_hours: 999,
        result_ttl_hours: 999,
        log_ttl_hours: 999,
        quarantine_ttl_hours: 999,
        cache_ttl_hours: 999,
        build_output_ttl_hours: 999,
        max_quarantine_count: nil,
        max_result_count: nil,
        max_log_count: nil,
        max_quarantine_bytes: nil,
        max_result_bytes: nil,
        max_log_bytes: nil,
        max_cache_bytes: nil,
        max_build_output_bytes: 20
      )

      expect(candidates.map(&:reason)).to include("build_output_bytes>20")
      expect(candidates.select { |item| item.reason == "build_output_bytes>20" }.map(&:task_ref)).to eq(["Sample#3231"])
    end
  end
end
