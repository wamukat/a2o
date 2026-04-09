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
