# frozen_string_literal: true

require "a3/bootstrap/container_builder"

RSpec.describe A3::Bootstrap::ContainerBuilder do
  def build_container(repositories:, runtime_services:)
    described_class.new(
      repositories: repositories,
      runtime_services: runtime_services
    ).build
  end

  def repositories_with_scheduler_store(task_repository:, run_repository:)
    scheduler_store = A3::Infra::InMemorySchedulerStore.new
    {
      storage_dir: "/tmp/a3-v2-test",
      task_repository: task_repository,
      run_repository: run_repository,
      scheduler_state_repository: A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store),
      scheduler_cycle_repository: A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store)
    }
  end

  def runtime_services_double_set
    {
      build_scope_snapshot: instance_double(A3::Application::BuildScopeSnapshot),
      build_artifact_owner: instance_double(A3::Application::BuildArtifactOwner),
      prepare_workspace: instance_double(A3::Application::PrepareWorkspace),
      plan_rerun: instance_double(A3::Application::PlanRerun),
      plan_next_runnable_task: instance_double(A3::Application::PlanNextRunnableTask),
      schedule_next_run: instance_double(A3::Application::ScheduleNextRun),
      build_merge_plan: instance_double(A3::Application::BuildMergePlan),
      run_verification: instance_double(A3::Application::RunVerification),
      run_worker_phase: instance_double(A3::Application::RunWorkerPhase),
      run_merge: instance_double(A3::Application::RunMerge),
      register_completed_run: instance_double(A3::Application::RegisterCompletedRun),
      start_run: instance_double(A3::Application::StartRun),
      workspace_provisioner: instance_double(A3::Infra::LocalWorkspaceProvisioner)
    }
  end

  it "reuses shared execution services inside execute_until_idle" do
    repositories = repositories_with_scheduler_store(
      task_repository: instance_double(A3::Infra::JsonTaskRepository),
      run_repository: instance_double(A3::Infra::JsonRunRepository)
    )
    runtime_services = runtime_services_double_set

    container = build_container(repositories: repositories, runtime_services: runtime_services)

    expect(container.fetch(:schedule_next_run)).to be(runtime_services.fetch(:schedule_next_run))
    expect(container.fetch(:execute_next_runnable_task)).to be_a(A3::Application::ExecuteNextRunnableTask)
    expect(container.fetch(:quarantine_terminal_task_workspaces)).to be_a(A3::Application::QuarantineTerminalTaskWorkspaces)
    scheduler_loop = container.fetch(:execute_until_idle).instance_variable_get(:@scheduler_loop)
    cycle_executor = scheduler_loop.instance_variable_get(:@cycle_executor)
    expect(cycle_executor.instance_variable_get(:@execute_next_runnable_task)).to be(container.fetch(:execute_next_runnable_task))
    quarantine_runner = scheduler_loop.instance_variable_get(:@quarantine_runner)
    expect(quarantine_runner.instance_variable_get(:@quarantine_terminal_task_workspaces)).to be(container.fetch(:quarantine_terminal_task_workspaces))
  end

  it "passes the exact scheduler repositories through to the scheduler cycle journal" do
    repositories = repositories_with_scheduler_store(
      task_repository: instance_double(A3::Infra::SqliteTaskRepository),
      run_repository: instance_double(A3::Infra::SqliteRunRepository)
    )
    runtime_services = runtime_services_double_set

    container = build_container(repositories: repositories, runtime_services: runtime_services)

    scheduler_loop = container.fetch(:execute_until_idle).instance_variable_get(:@scheduler_loop)
    cycle_journal = scheduler_loop.instance_variable_get(:@cycle_journal)

    expect(cycle_journal.instance_variable_get(:@scheduler_state_repository)).to be(repositories.fetch(:scheduler_state_repository))
    expect(cycle_journal.instance_variable_get(:@scheduler_cycle_repository)).to be(repositories.fetch(:scheduler_cycle_repository))
  end

  it "exposes operator and scheduler inspection use cases through the public container API" do
    repositories = repositories_with_scheduler_store(
      task_repository: instance_double(A3::Infra::SqliteTaskRepository),
      run_repository: instance_double(A3::Infra::SqliteRunRepository)
    )
    runtime_services = runtime_services_double_set

    container = build_container(repositories: repositories, runtime_services: runtime_services)

    expect(container.fetch(:show_blocked_diagnosis)).to be_a(A3::Application::ShowBlockedDiagnosis)
    expect(container.fetch(:show_run)).to be_a(A3::Application::ShowRun)
    expect(container.fetch(:show_task)).to be_a(A3::Application::ShowTask)
    expect(container.fetch(:show_scheduler_state)).to be_a(A3::Application::ShowSchedulerState)
    expect(container.fetch(:show_state)).to be_a(A3::Application::ShowState)
    expect(container.fetch(:repair_runs)).to be_a(A3::Application::RepairRuns)
    expect(container.fetch(:show_scheduler_history)).to be_a(A3::Application::ShowSchedulerHistory)
    expect(container.fetch(:pause_scheduler)).to be_a(A3::Application::PauseScheduler)
    expect(container.fetch(:resume_scheduler)).to be_a(A3::Application::ResumeScheduler)
  end

  it "preserves the public container API across execution operator and scheduler groupings" do
    repositories = repositories_with_scheduler_store(
      task_repository: instance_double(A3::Infra::JsonTaskRepository),
      run_repository: instance_double(A3::Infra::JsonRunRepository)
    )
    runtime_services = runtime_services_double_set

    container = build_container(repositories: repositories, runtime_services: runtime_services)

    expect(container.keys).to include(
      :task_repository,
      :run_repository,
      :storage_dir,
      :scheduler_state_repository,
      :scheduler_cycle_repository,
      :build_scope_snapshot,
      :build_artifact_owner,
      :prepare_workspace,
      :plan_persisted_rerun,
      :recover_persisted_rerun,
      :diagnose_blocked_run,
      :show_blocked_diagnosis,
      :show_task,
      :show_run,
      :show_scheduler_state,
      :show_state,
      :repair_runs,
      :show_scheduler_history,
      :pause_scheduler,
      :resume_scheduler,
      :plan_next_runnable_task,
      :schedule_next_run,
      :build_merge_plan,
      :run_verification,
      :run_worker_phase,
      :run_merge,
      :register_completed_run,
      :start_run,
      :execute_next_runnable_task,
      :execute_until_idle,
      :quarantine_terminal_task_workspaces
    )
  end
end
