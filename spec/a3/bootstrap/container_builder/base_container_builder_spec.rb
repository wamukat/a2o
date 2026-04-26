# frozen_string_literal: true

require "a3/bootstrap/container_builder"

RSpec.describe A3::Bootstrap::ContainerBuilder::BaseContainerBuilder do
  it "groups the base repositories and shared runtime values" do
    scheduler_store = A3::Infra::InMemorySchedulerStore.new
    repositories = {
      storage_dir: "/tmp/a3",
      task_repository: A3::Infra::InMemoryTaskRepository.new,
      run_repository: A3::Infra::InMemoryRunRepository.new,
      scheduler_state_repository: A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store),
      scheduler_cycle_repository: A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store)
    }
    runtime_services = {
      build_scope_snapshot: instance_double(A3::Application::BuildScopeSnapshot),
      build_artifact_owner: instance_double(A3::Application::BuildArtifactOwner),
      plan_next_decomposition_task: instance_double(A3::Application::PlanNextDecompositionTask)
    }
    context = A3::Bootstrap::ContainerBuilder::AssemblyContext.new(
      repositories: repositories,
      runtime_services: runtime_services
    )

    container = described_class.build(context: context)

    expect(container).to eq(
      task_repository: context.task_repository,
      storage_dir: context.storage_dir,
      run_repository: context.run_repository,
      scheduler_state_repository: context.scheduler_state_repository,
      scheduler_cycle_repository: context.scheduler_cycle_repository,
      build_scope_snapshot: context.build_scope_snapshot,
      build_artifact_owner: context.build_artifact_owner,
      plan_next_decomposition_task: context.plan_next_decomposition_task
    )
  end
end
