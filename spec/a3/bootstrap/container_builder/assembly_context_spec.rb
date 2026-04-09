# frozen_string_literal: true

require "a3/bootstrap/container_builder"

RSpec.describe A3::Bootstrap::ContainerBuilder::AssemblyContext do
  it "provides memoized access to repositories and runtime services" do
    scheduler_store = A3::Infra::InMemorySchedulerStore.new
    repositories = {
      task_repository: A3::Infra::InMemoryTaskRepository.new,
      run_repository: A3::Infra::InMemoryRunRepository.new,
      scheduler_state_repository: A3::Infra::InMemorySchedulerStateRepository.new(scheduler_store),
      scheduler_cycle_repository: A3::Infra::InMemorySchedulerCycleRepository.new(scheduler_store)
    }
    runtime_services = {
      build_scope_snapshot: instance_double(A3::Application::BuildScopeSnapshot),
      build_artifact_owner: instance_double(A3::Application::BuildArtifactOwner),
      plan_rerun: instance_double(A3::Application::PlanRerun),
      prepare_workspace: instance_double(A3::Application::PrepareWorkspace),
      workspace_provisioner: instance_double(A3::Infra::LocalWorkspaceProvisioner)
    }

    context = described_class.new(
      repositories: repositories,
      runtime_services: runtime_services
    )

    expect(context.task_repository).to be(repositories.fetch(:task_repository))
    expect(context.run_repository).to be(repositories.fetch(:run_repository))
    expect(context.scheduler_state_repository).to be(repositories.fetch(:scheduler_state_repository))
    expect(context.scheduler_cycle_repository).to be(repositories.fetch(:scheduler_cycle_repository))
    expect(context.build_scope_snapshot).to be(runtime_services.fetch(:build_scope_snapshot))
    expect(context.build_artifact_owner).to be(runtime_services.fetch(:build_artifact_owner))
    expect(context.plan_rerun).to be(runtime_services.fetch(:plan_rerun))
    expect(context.prepare_workspace).to be(runtime_services.fetch(:prepare_workspace))
    expect(context.workspace_provisioner).to be(runtime_services.fetch(:workspace_provisioner))
  end
end
