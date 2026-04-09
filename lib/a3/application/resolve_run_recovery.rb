# frozen_string_literal: true

module A3
  module Application
    class ResolveRunRecovery
      Result = Struct.new(:decision, :recovery, keyword_init: true)

      def initialize(plan_rerun:, build_scope_snapshot:, build_artifact_owner:)
        @plan_rerun = plan_rerun
        @build_scope_snapshot = build_scope_snapshot
        @build_artifact_owner = build_artifact_owner
      end

      def call(task:, run:, runtime_package:)
        decision = @plan_rerun.call(
          run: run,
          current_source_descriptor: run.evidence.source_descriptor,
          current_review_target: run.evidence.review_target,
          current_scope_snapshot: @build_scope_snapshot.call(task: task),
          current_artifact_owner: @build_artifact_owner.call(
            task: task,
            snapshot_version: run.evidence.artifact_owner.snapshot_version
          )
        ).decision

        Result.new(
          decision: decision,
          recovery: build_recovery(decision, runtime_package)
        ).freeze
      end

      private

      def build_recovery(decision, runtime_package)
        return nil if decision.to_sym == :terminal_noop

        doctor_result = A3::Application::DoctorRuntimeEnvironment.new(runtime_package: runtime_package).call
        A3::Domain::OperatorInspectionReadModel::RunView::RecoveryView.from_runtime_package(
          decision,
          doctor_result: doctor_result
        )
      end
    end
  end
end
