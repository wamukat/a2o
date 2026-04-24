# frozen_string_literal: true

module A3
  module Bootstrap
    class ContainerBuilder
      class OperatorGroupBuilder
        def self.build(context:, plan_persisted_rerun:)
          {
            plan_persisted_rerun: plan_persisted_rerun,
            recover_persisted_rerun: A3::Application::RecoverPersistedRerun.new(
              run_repository: context.run_repository,
              plan_persisted_rerun: plan_persisted_rerun
            ),
            diagnose_blocked_run: A3::Application::DiagnoseBlockedRun.new(
              task_repository: context.task_repository,
              run_repository: context.run_repository
            ),
            show_blocked_diagnosis: A3::Application::ShowBlockedDiagnosis.new(
              task_repository: context.task_repository,
              run_repository: context.run_repository,
              plan_rerun: context.plan_rerun,
              build_scope_snapshot: context.build_scope_snapshot,
              build_artifact_owner: context.build_artifact_owner
            ),
            show_task: A3::Application::ShowTask.new(
              task_repository: context.task_repository,
              run_repository: context.run_repository
            ),
            show_run: A3::Application::ShowRun.new(
              run_repository: context.run_repository,
              task_repository: context.task_repository,
              plan_rerun: context.plan_rerun,
              build_scope_snapshot: context.build_scope_snapshot,
              build_artifact_owner: context.build_artifact_owner
            ),
            show_scheduler_history: A3::Application::ShowSchedulerHistory.new(
              scheduler_cycle_repository: context.scheduler_cycle_repository
            ),
            list_skill_feedback: (list_skill_feedback = A3::Application::ListSkillFeedback.new(
              run_repository: context.run_repository
            )),
            generate_skill_feedback_proposal: A3::Application::GenerateSkillFeedbackProposal.new(
              list_skill_feedback: list_skill_feedback
            ),
            reconcile_manual_merge_recovery: context.reconcile_manual_merge_recovery
          }
        end
      end
    end
  end
end
