# frozen_string_literal: true

require "tmpdir"
require "a3/bootstrap/runtime_services_builder"

RSpec.describe A3::Bootstrap::RuntimeServicesBuilder::SchedulingGroupBuilder do
  it "builds scheduling services from support group" do
    Dir.mktmpdir do |dir|
      repositories = {
        task_repository: A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json")),
        run_repository: A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      }
      support_group = A3::Bootstrap::RuntimeServicesBuilder::SupportGroupBuilder.build(
        repositories: repositories,
        run_id_generator: -> { "run-1" },
        storage_dir: dir,
        repo_sources: { repo_beta: File.join(dir, "repo") }
      )

      result = described_class.build(
        repositories: repositories,
        support_group: support_group
      )

      expect(result.fetch(:plan_next_runnable_task)).to be_a(A3::Application::PlanNextRunnableTask)
      expect(result.fetch(:plan_next_decomposition_task)).to be_a(A3::Application::PlanNextDecompositionTask)
      expect(result.fetch(:start_run)).to be_a(A3::Application::StartRun)
      expect(result.fetch(:schedule_next_run)).to be_a(A3::Application::ScheduleNextRun)
    end
  end
end
