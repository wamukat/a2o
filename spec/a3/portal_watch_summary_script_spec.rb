# frozen_string_literal: true

require "tmpdir"
require_relative "../../../scripts/a3-projects/portal/portal_watch_summary"

RSpec.describe PortalWatchSummary do
  it "builds a ruby watch-summary command with portal-specific kanban bridge options" do
    command = described_class.watch_summary_command(
      storage_dirs: ["/tmp/custom-storage"],
      show_details: true
    )

    expect(command).to include("a3-engine/bin/a3")
    expect(command).to include("watch-summary")
    expect(command).to include("--kanban-command")
    expect(command).to include("task")
    expect(command).to include("--kanban-project")
    expect(command).to include("Portal")
    expect(command).to include("/tmp/custom-storage")
    expect(command).not_to include("--json")
    expect(command).not_to include("--show-details")
  end

  it "strips ansi escapes when no_color is requested" do
    allow(Open3).to receive(:capture3).and_return(["\e[36mScheduler: running\e[0m\n", "", instance_double(Process::Status, success?: true)])

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

    rendered = described_class.render_once(
      storage_dirs: [],
      show_details: false,
      json: true,
      no_color: true
    )

    payload = JSON.parse(rendered)
    expect(payload).to include(
      "rendered_text" => "Scheduler: idle\n\nTask Tree\n  (no tasks to watch)"
    )
  end
end
