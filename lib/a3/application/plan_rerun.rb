# frozen_string_literal: true

module A3
  module Application
    class PlanRerun
      Result = Struct.new(:decision, keyword_init: true)

      def initialize(policy: A3::Domain::RerunPolicy.new)
        @policy = policy
      end

      def call(run:, current_source_descriptor:, current_review_target:, current_scope_snapshot:, current_artifact_owner:)
        Result.new(
          decision: @policy.decide(
            run: run,
            current_source_descriptor: current_source_descriptor,
            current_review_target: current_review_target,
            current_scope_snapshot: current_scope_snapshot,
            current_artifact_owner: current_artifact_owner
          )
        )
      end
    end
  end
end
