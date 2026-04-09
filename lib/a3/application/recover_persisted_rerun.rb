# frozen_string_literal: true

module A3
  module Application
    class RecoverPersistedRerun
      class Result
        attr_reader :task, :run, :decision, :recovery_action, :target_phase, :recovery

        def initialize(task:, run:, decision:, recovery_action:, target_phase:, recovery:)
          @task = task
          @run = run
          @decision = decision.to_sym
          @recovery_action = recovery_action.to_sym
          @target_phase = target_phase.to_sym
          @recovery = recovery
          freeze
        end
      end

      def initialize(run_repository:, plan_persisted_rerun:)
        @run_repository = run_repository
        @plan_persisted_rerun = plan_persisted_rerun
      end

      def call(task_ref:, run_ref:, runtime_package:, current_source_type:, current_source_ref:, current_review_base:, current_review_head:, snapshot_version:)
        rerun_plan = @plan_persisted_rerun.call(
          task_ref: task_ref,
          run_ref: run_ref,
          current_source_type: current_source_type,
          current_source_ref: current_source_ref,
          current_review_base: current_review_base,
          current_review_head: current_review_head,
          snapshot_version: snapshot_version
        )

        build_result(rerun_plan, runtime_package: runtime_package)
      end

      private

      def build_result(rerun_plan, runtime_package:)
        recovery = build_recovery(rerun_plan.decision, runtime_package: runtime_package)

        case rerun_plan.decision.to_sym
        when :same_phase_retry
          Result.new(
            task: rerun_plan.task,
            run: rerun_plan.run,
            decision: :same_phase_retry,
            recovery_action: :retry_current_phase,
            target_phase: rerun_plan.run.phase,
            recovery: recovery
          )
        when :requires_new_implementation
          Result.new(
            task: rerun_plan.task,
            run: rerun_plan.run,
            decision: :requires_new_implementation,
            recovery_action: :start_new_implementation,
            target_phase: :implementation,
            recovery: recovery
          )
        when :requires_operator_action
          Result.new(
            task: rerun_plan.task,
            run: rerun_plan.run,
            decision: :requires_operator_action,
            recovery_action: :diagnose_blocked,
            target_phase: rerun_plan.run.phase,
            recovery: recovery
          )
        else
          raise A3::Domain::ConfigurationError, "persisted rerun recovery is not actionable: #{rerun_plan.decision}"
        end
      end

      def build_recovery(decision, runtime_package:)
        doctor_result = A3::Application::DoctorRuntimeEnvironment.new(runtime_package: runtime_package).call
        A3::Domain::OperatorInspectionReadModel::RecoverySnapshot.from_runtime_package(
          decision,
          doctor_result: doctor_result
        )
      end
    end
  end
end
