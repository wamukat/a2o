# frozen_string_literal: true

RSpec.describe A3::Application::SchedulerCycleExecutor do
  let(:execute_next_runnable_task) { instance_double(A3::Application::ExecuteNextRunnableTask) }
  let(:execute_runnable_task_batch) { instance_double(A3::Application::ExecuteRunnableTaskBatch) }
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
  let(:parallel_project_context) do
    A3::Domain::ProjectContext.new(
      surface: A3::Domain::ProjectSurface.new(
        implementation_skill: "skills/implementation/base.md",
        review_skill: "skills/review/base.md",
        verification_commands: ["commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        scheduler_config: A3::Domain::ProjectSchedulerConfig.new(max_parallel_tasks: 2),
        workspace_hook: "hooks/prepare-runtime.sh"
      ),
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only
      )
    )
  end
  let(:paused) { false }

  subject(:executor) do
    described_class.new(
      execute_next_runnable_task: execute_next_runnable_task,
      paused_checker: -> { paused }
    )
  end

  it "uses bounded batch execution when project parallelism is greater than one" do
    parallel_executor = described_class.new(
      execute_next_runnable_task: execute_next_runnable_task,
      execute_runnable_task_batch: execute_runnable_task_batch,
      paused_checker: -> { false }
    )
    batch = [
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started_1,
        execution_result: :result_1
      ),
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3031", kind: :child, edit_scope: [:repo_beta]),
        phase: :implementation,
        started_run: :started_2,
        execution_result: :result_2
      )
    ]
    allow(execute_runnable_task_batch).to receive(:call).with(
      project_context: parallel_project_context,
      max_steps: 3
    ).and_return(batch_result(executions: batch, idle: false))
    allow(execute_runnable_task_batch).to receive(:call).with(
      project_context: parallel_project_context,
      max_steps: 1
    ).and_return(batch_result(executions: [], idle: true))
    allow(execute_next_runnable_task).to receive(:call)

    result = parallel_executor.call(project_context: parallel_project_context, max_steps: 3)

    expect(result.executed_count).to eq(2)
    expect(result.idle_reached).to eq(true)
    expect(execute_next_runnable_task).not_to have_received(:call)
  end

  it "does not mark an empty parallel batch as idle when planning is blocked by active work" do
    parallel_executor = described_class.new(
      execute_next_runnable_task: execute_next_runnable_task,
      execute_runnable_task_batch: execute_runnable_task_batch,
      paused_checker: -> { false }
    )
    allow(execute_runnable_task_batch).to receive(:call).and_return(
      batch_result(executions: [], idle: false, busy: true)
    )

    result = parallel_executor.call(project_context: parallel_project_context, max_steps: 3)

    expect(result.executed_count).to eq(0)
    expect(result.idle_reached).to eq(false)
  end

  it "collects runnable executions until idle" do
    allow(execute_next_runnable_task).to receive(:call).and_return(
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started_1,
        execution_result: :result_1
      ),
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3031", kind: :child, edit_scope: [:repo_beta]),
        phase: :review,
        started_run: :started_2,
        execution_result: :result_2
      ),
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: nil,
        phase: nil,
        started_run: nil,
        execution_result: nil
      )
    )

    result = executor.call(project_context: project_context, max_steps: 5)

    expect(result.executed_count).to eq(2)
    expect(result.idle_reached).to eq(true)
    expect(result.paused_reached).to eq(false)
    expect(result.executions.map(&:phase)).to eq(%i[implementation review])
  end

  it "respects the max_steps guard without forcing idle" do
    allow(execute_next_runnable_task).to receive(:call).and_return(
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started_1,
        execution_result: :result_1
      )
    )

    result = executor.call(project_context: project_context, max_steps: 1)

    expect(result.executed_count).to eq(1)
    expect(result.idle_reached).to eq(false)
    expect(result.paused_reached).to eq(false)
    expect(result.executions.size).to eq(1)
  end

  it "stops after the current execution when pause is requested mid-cycle" do
    paused_state = false
    allow(execute_next_runnable_task).to receive(:call) do
      paused_state = true
      A3::Application::ExecuteNextRunnableTask::Result.new(
        task: A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha]),
        phase: :implementation,
        started_run: :started_1,
        execution_result: :result_1
      )
    end
    allow(executor.instance_variable_get(:@paused_checker)).to receive(:call) { paused_state }

    result = executor.call(project_context: project_context, max_steps: 5)

    expect(result.executed_count).to eq(1)
    expect(result.idle_reached).to eq(false)
    expect(result.paused_reached).to eq(true)
  end

  def batch_result(executions:, idle:, busy: false)
    plan = instance_double(
      A3::Application::PlanRunnableTaskBatch::Result,
      idle?: idle,
      busy?: busy,
      waiting?: false
    )
    A3::Application::ExecuteRunnableTaskBatch::Result.new(
      executions: executions,
      batch_plan: plan
    )
  end
end
