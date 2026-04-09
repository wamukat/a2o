# frozen_string_literal: true

module A3
  module Domain
    class RerunPolicy
      def decide(run:, current_source_descriptor:, current_review_target:, current_scope_snapshot:, current_artifact_owner:)
        if run.terminal?
          return :terminal_noop if %i[completed terminal_noop].include?(run.terminal_outcome)
          return :same_phase_retry if run.terminal_outcome == :retryable && same_intent?(run, current_source_descriptor, current_review_target, current_scope_snapshot, current_artifact_owner)

          return :requires_operator_action
        end

        return :same_phase_retry if same_intent?(run, current_source_descriptor, current_review_target, current_scope_snapshot, current_artifact_owner)
        return :requires_new_implementation if run.evidence.review_target != current_review_target

        :requires_operator_action
      end

      private

      def same_intent?(run, current_source_descriptor, current_review_target, current_scope_snapshot, current_artifact_owner)
        run.evidence.source_descriptor == current_source_descriptor &&
          run.evidence.review_target == current_review_target &&
          run.evidence.scope_snapshot == current_scope_snapshot &&
          run.evidence.artifact_owner == current_artifact_owner
      end
    end
  end
end
