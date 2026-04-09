# frozen_string_literal: true

require "tmpdir"
require "a3/bootstrap/runtime_services_builder"

RSpec.describe A3::Bootstrap::RuntimeServicesBuilder::ExecutionGroupBuilder do
  it "builds execution services from support group" do
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
        support_group: support_group,
        command_runner: instance_double(A3::Infra::LocalCommandRunner),
        merge_runner: instance_double(A3::Infra::LocalMergeRunner),
        worker_gateway: instance_double(A3::Infra::LocalWorkerGateway),
        external_task_source: A3::Infra::NullExternalTaskSource.new
      )

      expect(result.fetch(:build_merge_plan)).to be_a(A3::Application::BuildMergePlan)
      expect(result.fetch(:run_worker_phase)).to be_a(A3::Application::RunWorkerPhase)
      expect(result.fetch(:run_verification)).to be_a(A3::Application::RunVerification)
      expect(result.fetch(:run_merge)).to be_a(A3::Application::RunMerge)
    end
  end
end
