# frozen_string_literal: true

require "a3/infra/integration_ref_readiness_checker"

module A3
  module Bootstrap
    class RuntimeServicesBuilder
      class SupportGroupBuilder
        def self.build(repositories:, run_id_generator:, storage_dir:, repo_sources:, external_task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new, external_task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new, external_follow_up_child_writer: nil)
          workspace_plan_builder = A3::Application::BuildWorkspacePlan.new(repo_slots: repo_sources.keys)
          start_phase = A3::Application::StartPhase.new(
            workspace_plan_builder: workspace_plan_builder,
            run_id_generator: run_id_generator
          )
          integration_ref_readiness_checker = A3::Infra::IntegrationRefReadinessChecker.new(repo_sources: repo_sources)
          parent_review_disposition_handler = build_parent_review_disposition_handler(external_follow_up_child_writer)
          register_started_run = A3::Application::RegisterStartedRun.new(
            task_repository: repositories.fetch(:task_repository),
            run_repository: repositories.fetch(:run_repository),
            publish_external_task_status: external_task_status_publisher,
            publish_external_task_activity: external_task_activity_publisher
          )
          register_completed_run = A3::Application::RegisterCompletedRun.new(
            task_repository: repositories.fetch(:task_repository),
            run_repository: repositories.fetch(:run_repository),
            plan_next_phase: A3::Application::PlanNextPhase.new,
            publish_external_task_status: external_task_status_publisher,
            publish_external_task_activity: external_task_activity_publisher,
            integration_ref_readiness_checker: integration_ref_readiness_checker,
            handle_parent_review_disposition: parent_review_disposition_handler
          )
          build_scope_snapshot = A3::Application::BuildScopeSnapshot.new
          build_artifact_owner = A3::Application::BuildArtifactOwner.new
          workspace_provisioner = A3::Infra::LocalWorkspaceProvisioner.new(
            base_dir: storage_dir,
            repo_sources: repo_sources
          )
          prepare_workspace = A3::Application::PrepareWorkspace.new(
            workspace_plan_builder: workspace_plan_builder,
            provisioner: workspace_provisioner
          )

          {
            start_phase: start_phase,
            register_started_run: register_started_run,
            register_completed_run: register_completed_run,
            build_scope_snapshot: build_scope_snapshot,
            build_artifact_owner: build_artifact_owner,
            integration_ref_readiness_checker: integration_ref_readiness_checker,
            workspace_provisioner: workspace_provisioner,
            prepare_workspace: prepare_workspace,
            plan_rerun: A3::Application::PlanRerun.new,
            external_task_status_publisher: external_task_status_publisher,
            external_task_activity_publisher: external_task_activity_publisher
          }
        end

        def self.build_parent_review_disposition_handler(external_follow_up_child_writer)
          return nil unless external_follow_up_child_writer

          A3::Application::HandleParentReviewDisposition.new(
            follow_up_child_writer: external_follow_up_child_writer
          )
        end
      end
    end
  end
end
