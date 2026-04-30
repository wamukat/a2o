# frozen_string_literal: true

module A3
  module Infra
    class SharedRefLockingMergeRunner
      def initialize(inner:, lock_guard:)
        @inner = inner
        @lock_guard = lock_guard
      end

      def run(merge_plan, workspace:)
        @lock_guard.with_locks(lock_requests_for(merge_plan)) do
          @inner.run(merge_plan, workspace: workspace)
        end
      end

      def agent_owned?
        @inner.respond_to?(:agent_owned?) && @inner.agent_owned?
      end

      private

      def lock_requests_for(merge_plan)
        merge_plan.merge_slots.map do |slot|
          {
            operation: :merge,
            repo_slot: slot,
            target_ref: merge_plan.integration_target.target_ref,
            run_ref: merge_plan.run_ref,
            project_key: merge_plan.project_key
          }
        end
      end
    end
  end
end
