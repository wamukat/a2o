# frozen_string_literal: true

require "tmpdir"
require_relative "../../../scripts/a3/portal_v2_watch_summary"

RSpec.describe PortalV2WatchSummary do
  it "extracts the most relevant launchd error from stderr logs" do
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "launchd.stderr.log")
      File.write(
        log_path,
        [
          "from somewhere",
          "/Users/takuma/workspace/mypage-prototype/a3-v2/lib/a3/infra/kanban_cli_task_source.rb:207:in `run_json_command': kanban command failed (exit=1): KANBOARD_API_TOKEN is required. (A3::Domain::ConfigurationError)"
        ].join("\n")
      )

      detail = described_class.extract_recent_launchd_error(Pathname(log_path))

      expect(detail).to eq("kanban command failed (exit=1): KANBOARD_API_TOKEN is required. (A3::Domain::ConfigurationError)")
    end
  end

  it "overlays failed scheduler runtime status onto rendered output" do
    rendered = "Scheduler: idle\n\nTask Tree\n [x] #1 Done"

    result = described_class.overlay_scheduler_runtime_status(
      rendered,
      described_class::SchedulerRuntimeStatus.new(
        state: "failed",
        exit_code: 1,
        detail: "kanban command failed (exit=1): KANBOARD_API_TOKEN is required."
      )
    )

    expect(result).to include("Scheduler: failed (launchd exit=1)")
    expect(result).to include("detail: kanban command failed (exit=1): KANBOARD_API_TOKEN is required.")
  end

  it "builds a ruby watch-summary command with portal-specific kanban bridge options" do
    command = described_class.watch_summary_command(
      storage_dirs: ["/tmp/custom-storage"],
      show_details: true
    )

    expect(command).to include("a3-engine/bin/a3")
    expect(command).to include("watch-summary")
    expect(command).to include("--kanban-command")
    expect(command).to include("python3")
    expect(command).to include("--kanban-project")
    expect(command).to include("Portal")
    expect(command).to include("/tmp/custom-storage")
    expect(command).not_to include("--json")
    expect(command).not_to include("--show-details")
  end

  it "strips ansi escapes when no_color is requested" do
    allow(Open3).to receive(:capture3).and_return(["\e[36mScheduler: running\e[0m\n", "", instance_double(Process::Status, success?: true)])
    allow(described_class).to receive(:load_scheduler_runtime_status).and_return(nil)

    rendered = described_class.render_once(
      storage_dirs: [],
      show_details: false,
      json: false,
      no_color: true
    )

    expect(rendered).to eq("Scheduler: running")
  end

  it "renders wrapper-owned json without passing --json to the cli" do
    allow(Open3).to receive(:capture3).and_return(["Scheduler: idle\n\nTask Tree\n  (no tasks to watch)\n", "", instance_double(Process::Status, success?: true)])
    allow(described_class).to receive(:load_scheduler_runtime_status).and_return(
      described_class::SchedulerRuntimeStatus.new(state: "idle", exit_code: 0, detail: nil)
    )

    rendered = described_class.render_once(
      storage_dirs: [],
      show_details: false,
      json: true,
      no_color: true
    )

    payload = JSON.parse(rendered)
    expect(payload).to include(
      "rendered_text" => "Scheduler: idle\n\nTask Tree\n  (no tasks to watch)",
      "scheduler_runtime" => {
        "state" => "idle",
        "exit_code" => 0,
        "detail" => nil
      }
    )
  end
end
