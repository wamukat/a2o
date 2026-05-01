# frozen_string_literal: true

require "a3/bootstrap/container_builder"

RSpec.describe A3::Bootstrap::ContainerBuilder::SharedServicesBuilder do
  it "groups shared orchestration services for the container builder" do
    scheduler_store = A3::Infra::InMemorySchedulerStore.new
    repositories = {
      task_repository: A3::Infra::InMemoryTaskRepository.new,
      run_repository: A3::Infra::InMemoryRunRepository.new,
      scheduler_state_repository: A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store),
      scheduler_cycle_repository: A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store),
      task_claim_repository: A3::Infra::InMemorySchedulerTaskClaimRepository.new
    }
    runtime_services = {
      plan_rerun: instance_double(A3::Application::PlanRerun),
      build_scope_snapshot: instance_double(A3::Application::BuildScopeSnapshot),
      build_artifact_owner: instance_double(A3::Application::BuildArtifactOwner),
      plan_runnable_task_batch: instance_double(A3::Application::PlanRunnableTaskBatch),
      schedule_next_run: instance_double(A3::Application::ScheduleNextRun),
      run_worker_phase: instance_double(A3::Application::RunWorkerPhase),
      run_verification: instance_double(A3::Application::RunVerification),
      run_merge: instance_double(A3::Application::RunMerge),
      workspace_provisioner: instance_double(A3::Infra::LocalWorkspaceProvisioner)
    }
    context = A3::Bootstrap::ContainerBuilder::AssemblyContext.new(
      repositories: repositories,
      runtime_services: runtime_services
    )

    services = described_class.build(context: context)

    expect(services.fetch(:plan_persisted_rerun)).to be_a(A3::Application::PlanPersistedRerun)
    expect(services.fetch(:execute_next_runnable_task)).to be_a(A3::Application::ExecuteNextRunnableTask)
    expect(services.fetch(:quarantine_terminal_task_workspaces)).to be_a(A3::Application::QuarantineTerminalTaskWorkspaces)
    expect(services.fetch(:execute_until_idle)).to be_a(A3::Application::ExecuteUntilIdle)
  end
end
