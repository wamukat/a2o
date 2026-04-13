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

  it "reports cleanup paths and blocked labels as not ready" do
    Dir.mktmpdir("a3-rerun-readiness-") do |dir|
      root = Pathname(dir)
      issue_workspace = root.join(".work", "a3", "issues", "portal", "portal-2981")
      FileUtils.mkdir_p(issue_workspace.join(".work"))
      File.symlink(".support/member-portal-ui-app/member-portal-starters", issue_workspace.join("member-portal-starters"))

      active_runs = root.join(".work", "a3", "state", "portal", "active-runs.json")
      worker_runs = root.join(".work", "a3", "state", "portal", "worker-runs.json")
      write_json(active_runs, { "active_task_refs" => [] })
      write_json(
        worker_runs,
        {
          "runs" => {
            "Portal#2981" => {
              "task_ref" => "Portal#2981",
              "task_id" => 2981,
              "team" => "review",
              "phase" => "review",
              "state" => "blocked",
              "started_at" => "2026-04-02T14:24:20+09:00",
              "heartbeat_at" => "2026-04-02T14:24:20+09:00",
              "updated_at_epoch_ms" => 1
            }
          }
        }
      )

      allow(described_class).to receive(:inspect_kanban_task).and_return(["In review", false, ["blocked"]])

      result = described_class.inspect_rerun_readiness(
        root_dir: root,
        project: "portal",
        task_ref: "Portal#2981",
        active_runs_file: active_runs,
        worker_runs_file: worker_runs,
        kanban_project: "Portal"
      )

      expect(result.fetch("ready")).to eq(false)
      expect(result.fetch("cleanup_paths")).to include(issue_workspace.join(".work").to_s)
      expect(result.fetch("cleanup_paths")).to include(issue_workspace.join("member-portal-starters").to_s)
      by_name = result.fetch("checks").each_with_object({}) { |item, acc| acc[item.fetch("name")] = item }
      expect(by_name.fetch("broken_support_bridges_cleared").fetch("ok")).to eq(false)
      expect(by_name.fetch("rerun_cleanup_paths_cleared").fetch("ok")).to eq(false)
      expect(by_name.fetch("blocked_label_cleared").fetch("ok")).to eq(false)
    end
  end

  it "allows blocked labels for explicit reruns" do
    Dir.mktmpdir("a3-rerun-readiness-") do |dir|
      root = Pathname(dir)
      active_runs = root.join(".work", "a3", "state", "portal", "active-runs.json")
      worker_runs = root.join(".work", "a3", "state", "portal", "worker-runs.json")
      write_json(active_runs, { "active_task_refs" => [] })
      write_json(
        worker_runs,
        {
          "runs" => {
            "Portal#2981" => {
              "task_ref" => "Portal#2981",
              "task_id" => 2981,
              "team" => "review",
              "phase" => "review",
              "state" => "blocked",
              "started_at" => "2026-04-02T14:24:20+09:00",
              "heartbeat_at" => "2026-04-02T14:24:20+09:00",
              "updated_at_epoch_ms" => 1
            }
          }
        }
      )

      allow(described_class).to receive(:inspect_kanban_task).and_return(["In review", false, ["blocked"]])

      result = described_class.inspect_rerun_readiness(
        root_dir: root,
        project: "portal",
        task_ref: "Portal#2981",
        active_runs_file: active_runs,
        worker_runs_file: worker_runs,
        kanban_project: "Portal",
        allow_blocked_label: true
      )

      expect(result.fetch("ready")).to eq(true)
      blocked_check = result.fetch("checks").find { |item| item.fetch("name") == "blocked_label_cleared" }
      expect(blocked_check.fetch("ok")).to eq(true)
      expect(blocked_check.fetch("blocking")).to eq(false)
    end
  end
end
