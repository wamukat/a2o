# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class RunnableAssessment
        attr_reader :phase, :reason, :blocking_task_refs

        def initialize(phase:, reason:, blocking_task_refs:)
          @phase = phase&.to_sym
          @reason = reason.to_sym
          @blocking_task_refs = Array(blocking_task_refs).map(&:to_s).freeze
          freeze
        end

        def self.from_assessment(assessment)
          new(
            phase: assessment.phase,
            reason: assessment.reason,
            blocking_task_refs: assessment.blocking_task_refs
          )
        end
      end
    end
  end
end
