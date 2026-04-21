# frozen_string_literal: true

module A3
  module Domain
    class UpstreamLineGuard
      def initialize(inherited_parent_state_resolver: nil)
        @inherited_parent_state_resolver = inherited_parent_state_resolver
      end

      Assessment = Struct.new(:healthy, :reason, :blocking_task_refs, keyword_init: true) do
        def healthy?
          !!healthy
        end
      end

      def evaluate(task:, phase:, tasks:, runs:)
        current_snapshot = @inherited_parent_state_resolver&.snapshot_for(task: task, phase: phase)
        return healthy_assessment unless current_snapshot

        blocked_refs = verification_blocked_sibling_refs(task, tasks, runs, current_snapshot)
        return healthy_assessment if blocked_refs.empty?

        Assessment.new(
          healthy: false,
          reason: :upstream_unhealthy,
          blocking_task_refs: blocked_refs.freeze
        )
      end

      private

      def verification_blocked_sibling_refs(task, tasks, runs, current_snapshot)
        runs_by_task = Array(runs).group_by(&:task_ref)
        siblings_for(task, tasks).select do |candidate|
          candidate.status == :blocked && latest_run_verification_blocked?(runs_by_task.fetch(candidate.ref, []).last, current_snapshot)
        end.map(&:ref)
      end

      def siblings_for(task, tasks)
        Array(tasks).select do |candidate|
          candidate.ref != task.ref && candidate.parent_ref == task.parent_ref
        end
      end

      def latest_run_verification_blocked?(run, current_snapshot)
        return false unless run&.terminal_outcome == :blocked

        phase_record = run.phase_records.reverse_each.find { |record| !record.blocked_diagnosis.nil? }
        diagnosis = phase_record&.blocked_diagnosis
        return false unless diagnosis&.error_category == "verification_failed"

        diagnostics = phase_record.execution_record&.diagnostics || {}
        diagnostics["inherited_parent_ref"] == current_snapshot.ref &&
          diagnostics["inherited_parent_state_fingerprint"] == current_snapshot.fingerprint
      end

      def healthy_assessment
        Assessment.new(healthy: true, reason: :healthy, blocking_task_refs: [].freeze)
      end
    end
  end
end
