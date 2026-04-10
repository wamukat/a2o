# frozen_string_literal: true

RSpec.describe A3::Application::SchedulerQuarantineRunner do
  it "returns zero when a null quarantine implementation is used" do
    runner = described_class.new(
      quarantine_terminal_task_workspaces: A3::Application::NullQuarantineTerminalTaskWorkspaces.new
    )

    expect(runner.call).to eq(0)
  end

  it "returns the number of quarantined workspaces" do
    quarantine_terminal_task_workspaces = instance_double(A3::Application::QuarantineTerminalTaskWorkspaces)
    allow(quarantine_terminal_task_workspaces).to receive(:call).and_return(
      A3::Application::QuarantineTerminalTaskWorkspaces::Result.new(
        quarantined: [
          A3::Application::QuarantineTerminalTaskWorkspaces::QuarantinedWorkspace.new(
            task_ref: "A3-v2#3025",
            quarantine_path: "/tmp/quarantine/A3-v2-3025"
          )
        ]
      )
    )

    runner = described_class.new(quarantine_terminal_task_workspaces: quarantine_terminal_task_workspaces)

    expect(runner.call).to eq(1)
  end
end

RSpec.describe A3::Application::SchedulerCleanupRunner do
  it "runs terminal cleanup for done and blocked task workspaces" do
    cleanup_terminal_task_workspaces = instance_double(A3::Application::CleanupTerminalTaskWorkspaces)
    allow(cleanup_terminal_task_workspaces).to receive(:call).and_return(
      A3::Application::CleanupTerminalTaskWorkspaces::Result.new(
        cleaned: [
          A3::Application::CleanupTerminalTaskWorkspaces::CleanedWorkspace.new(
            task_ref: "A3-v2#3025",
            status: :done,
            cleaned_paths: ["/tmp/workspaces/A3-v2-3025/runtime_workspace"]
          )
        ],
        dry_run: false,
        statuses: %i[done blocked],
        scopes: %i[ticket_workspace runtime_workspace]
      )
    )

    runner = described_class.new(cleanup_terminal_task_workspaces: cleanup_terminal_task_workspaces)

    expect(runner.call).to eq(1)
    expect(cleanup_terminal_task_workspaces).to have_received(:call).with(
      statuses: %i[done blocked],
      scopes: %i[ticket_workspace runtime_workspace],
      dry_run: false
    )
  end
end
