# frozen_string_literal: true

RSpec.describe A3::Application::ExecuteUntilIdle do
  let(:execute_next_runnable_task) { instance_double(A3::Application::ExecuteNextRunnableTask) }
  let(:scheduler_store) { A3::Infra::InMemorySchedulerStore.new }
  let(:scheduler_cycle_journal) do
    A3::Application::SchedulerCycleJournal.new(
      scheduler_state_repository: A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store),
      scheduler_cycle_repository: A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store)
    )
  end
  let(:state_repository) { A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store) }
  let(:cycle_repository) { A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store) }
  let(:quarantine_terminal_task_workspaces) { instance_double(A3::Application::QuarantineTerminalTaskWorkspaces) }
  let(:project_context) do
    A3::Domain::ProjectContext.new(
      surface: A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation/base.md",
        review_skill: "skills/review/base.md",
        verification_commands: ["commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        workspace_hook: "hooks/prepare-runtime.sh"
      ),
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only
      )
    )
  end

  subject(:use_case) do
    described_class.new(
      execute_next_runnable_task: execute_next_runnable_task,
      cycle_journal: scheduler_cycle_journal,
      quarantine_terminal_task_workspaces: quarantine_terminal_task_workspaces
    )
  end

  it "persists stop reason and executed count after a cycle" do
    allow(quarantine_terminal_task_workspaces).to receive(:call).and_return(
      A3::Application::QuarantineTerminalTaskWorkspaces::Result.new(quarantined: [])
    )
    allow(execute_next_runnable_task).to receive(:call).and_return(
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started,
        execution_result: :result
      ),
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: nil,
        phase: nil,
        started_run: nil,
        execution_result: nil
      )
    )

    result = use_case.call(project_context: project_context)

    expect(result.stop_reason).to eq(:idle)
    persisted = state_repository.fetch
    expect(persisted.last_stop_reason).to eq(:idle)
    expect(persisted.last_executed_count).to eq(1)
    expect(cycle_repository.all.size).to eq(1)
    expect(cycle_repository.all.first.stop_reason).to eq(:idle)
  end

  it "quarantines terminal workspaces after reaching idle" do
    allow(execute_next_runnable_task).to receive(:call).and_return(
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: nil,
        phase: nil,
        started_run: nil,
        execution_result: nil
      )
    )
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

    result = use_case.call(project_context: project_context)

    expect(result.stop_reason).to eq(:idle)
    expect(result.quarantined_count).to eq(1)
    expect(quarantine_terminal_task_workspaces).to have_received(:call)
  end

  it "does not execute when the scheduler is paused" do
    allow(execute_next_runnable_task).to receive(:call)
    allow(quarantine_terminal_task_workspaces).to receive(:call)
    state_repository.save(A3::Domain::SchedulerState.new(paused: true))

    result = use_case.call(project_context: project_context)

    expect(result.executed_count).to eq(0)
    expect(result.stop_reason).to eq(:paused)
    expect(execute_next_runnable_task).not_to have_received(:call)
    expect(quarantine_terminal_task_workspaces).not_to have_received(:call)
  end
end
