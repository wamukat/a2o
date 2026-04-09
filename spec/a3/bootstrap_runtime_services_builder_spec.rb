# frozen_string_literal: true

require "tmpdir"
require "a3/bootstrap/runtime_services_builder"

RSpec.describe A3::Bootstrap::RuntimeServicesBuilder do
  it "builds shared runtime services for schedule and execution use cases" do
    Dir.mktmpdir do |dir|
      repositories = {
        task_repository: A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json")),
        run_repository: A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      }

      runtime_services = described_class.new(
        repositories: repositories,
        run_id_generator: -> { "run-1" },
        command_runner: instance_double(A3::Infra::LocalCommandRunner),
        merge_runner: instance_double(A3::Infra::LocalMergeRunner),
        worker_gateway: instance_double(A3::Infra::LocalWorkerGateway),
        storage_dir: dir,
        repo_sources: { repo_beta: File.join(dir, "repo") }
      ).build

      expect(runtime_services.fetch(:start_phase)).to be_a(A3::Application::StartPhase)
      expect(runtime_services.fetch(:register_started_run)).to be_a(A3::Application::RegisterStartedRun)
      expect(runtime_services.fetch(:register_completed_run)).to be_a(A3::Application::RegisterCompletedRun)
      expect(runtime_services.fetch(:schedule_next_run)).to be_a(A3::Application::ScheduleNextRun)
      expect(runtime_services.fetch(:run_worker_phase)).to be_a(A3::Application::RunWorkerPhase)
      expect(runtime_services.fetch(:run_verification)).to be_a(A3::Application::RunVerification)
      expect(runtime_services.fetch(:run_merge)).to be_a(A3::Application::RunMerge)
      expect(runtime_services.fetch(:build_merge_plan)).to be_a(A3::Application::BuildMergePlan)
      expect(runtime_services.fetch(:workspace_provisioner)).to be_a(A3::Infra::LocalWorkspaceProvisioner)
    end
  end
end
