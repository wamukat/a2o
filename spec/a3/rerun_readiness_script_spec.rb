# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "a3/operator/rerun_readiness"

RSpec.describe A3RerunReadiness do
  def write_json(path, payload)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(payload) + "\n")
  end

  def write_agent_job_for(path, task_ref:, phase:, state:)
    write_json(
      path.dirname.join("agent_jobs.json"),
      {
        "job-#{task_ref.delete('#')}" => {
          "state" => "completed",
          "claimed_at" => "2026-04-02T14:24:20+09:00",
          "heartbeat_at" => "2026-04-02T14:24:20+09:00",
          "request" => { "job_id" => "job-#{task_ref.delete('#')}", "task_ref" => task_ref, "phase" => phase },
          "result" => { "status" => "success", "activity_state" => state }
        }
      }
    )
  end

  it "reports cleanup paths and blocked labels as not ready" do
    Dir.mktmpdir("a3-rerun-readiness-") do |dir|
      root = Pathname(dir)
      issue_workspace = root.join(".work", "a3", "issues", "sample", "sample-2981")
      FileUtils.mkdir_p(issue_workspace.join(".work"))
      File.symlink(".support/sample-storefront/sample-catalog-service", issue_workspace.join("sample-catalog-service"))

      active_runs = root.join(".work", "a3", "state", "sample", "active-runs.json")
      worker_runs = root.join(".work", "a3", "state", "sample", "worker-runs.json")
      write_json(active_runs, { "active_task_refs" => [] })
      write_agent_job_for(worker_runs, task_ref: "Sample#2981", phase: "review", state: "blocked")

      allow(described_class).to receive(:inspect_kanban_task).and_return(["In review", false, ["blocked"]])

      result = described_class.inspect_rerun_readiness(
        root_dir: root,
        project: "sample",
        task_ref: "Sample#2981",
        active_runs_file: active_runs,
        worker_runs_file: worker_runs,
        kanban_project: "Sample"
      )

      expect(result.fetch("ready")).to eq(false)
      expect(result.fetch("cleanup_paths")).to include(issue_workspace.join(".work").to_s)
      expect(result.fetch("cleanup_paths")).to include(issue_workspace.join("sample-catalog-service").to_s)
      by_name = result.fetch("checks").each_with_object({}) { |item, acc| acc[item.fetch("name")] = item }
      expect(by_name.fetch("broken_support_bridges_cleared").fetch("ok")).to eq(false)
      expect(by_name.fetch("rerun_cleanup_paths_cleared").fetch("ok")).to eq(false)
      expect(by_name.fetch("blocked_label_cleared").fetch("ok")).to eq(false)
    end
  end

  it "allows blocked labels for explicit reruns" do
    Dir.mktmpdir("a3-rerun-readiness-") do |dir|
      root = Pathname(dir)
      active_runs = root.join(".work", "a3", "state", "sample", "active-runs.json")
      worker_runs = root.join(".work", "a3", "state", "sample", "worker-runs.json")
      write_json(active_runs, { "active_task_refs" => [] })
      write_agent_job_for(worker_runs, task_ref: "Sample#2981", phase: "review", state: "blocked")

      allow(described_class).to receive(:inspect_kanban_task).and_return(["In review", false, ["blocked"]])

      result = described_class.inspect_rerun_readiness(
        root_dir: root,
        project: "sample",
        task_ref: "Sample#2981",
        active_runs_file: active_runs,
        worker_runs_file: worker_runs,
        kanban_project: "Sample",
        allow_blocked_label: true
      )

      expect(result.fetch("ready")).to eq(true)
      blocked_check = result.fetch("checks").find { |item| item.fetch("name") == "blocked_label_cleared" }
      expect(blocked_check.fetch("ok")).to eq(true)
      expect(blocked_check.fetch("blocking")).to eq(false)
    end
  end
end
