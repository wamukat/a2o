# frozen_string_literal: true

require "tmpdir"
require "a3/bootstrap/runtime_services_builder"

RSpec.describe A3::Bootstrap::RuntimeServicesBuilder::SupportGroupBuilder do
  it "builds shared support services" do
    Dir.mktmpdir do |dir|
      repositories = {
        task_repository: A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json")),
        run_repository: A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      }

      result = described_class.build(
        repositories: repositories,
        run_id_generator: -> { "run-1" },
        storage_dir: dir,
        repo_sources: { repo_beta: File.join(dir, "repo") }
      )

      expect(result.fetch(:start_phase)).to be_a(A3::Application::StartPhase)
      expect(result.fetch(:register_started_run)).to be_a(A3::Application::RegisterStartedRun)
      expect(result.fetch(:register_completed_run)).to be_a(A3::Application::RegisterCompletedRun)
      expect(result.fetch(:build_scope_snapshot)).to be_a(A3::Application::BuildScopeSnapshot)
      expect(result.fetch(:build_artifact_owner)).to be_a(A3::Application::BuildArtifactOwner)
      expect(result.fetch(:workspace_provisioner)).to be_a(A3::Infra::LocalWorkspaceProvisioner)
      expect(result.fetch(:prepare_workspace)).to be_a(A3::Application::PrepareWorkspace)
      expect(result.fetch(:plan_rerun)).to be_a(A3::Application::PlanRerun)
    end
  end

  it "builds parent review disposition handler from explicit follow-up writer" do
    writer = instance_double(A3::Infra::KanbanCliFollowUpChildWriter)

    handler = described_class.build_parent_review_disposition_handler(writer)

    expect(handler).to be_a(A3::Application::HandleParentReviewDisposition)
    expect(handler.instance_variable_get(:@follow_up_child_writer)).to eq(writer)
  end
end
