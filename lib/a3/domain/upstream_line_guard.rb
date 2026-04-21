# frozen_string_literal: true

module A3
  module Domain
    class UpstreamLineGuard
      Assessment = Struct.new(:healthy, :reason, :blocking_task_refs, keyword_init: true) do
        def healthy?
          !!healthy
        end
      end

      def evaluate(task:, phase:, tasks:, runs:)
        return healthy_assessment unless child_phase_guarded?(task, phase)

        blocked_refs = verification_blocked_sibling_refs(task, tasks, runs)
        return healthy_assessment if blocked_refs.empty?

        Assessment.new(
          healthy: false,
          reason: :upstream_unhealthy,
          blocking_task_refs: blocked_refs.freeze
        )
      end

      private

      def child_phase_guarded?(task, phase)
        return false unless task.kind == :child
        return false if task.parent_ref.to_s.empty?
        return false if phase.nil?

        %i[implementation verification].include?(phase.to_sym)
      end

      def verification_blocked_sibling_refs(task, tasks, runs)
        runs_by_task = Array(runs).group_by(&:task_ref)
        siblings_for(task, tasks).select do |candidate|
          candidate.status == :blocked && latest_run_verification_blocked?(runs_by_task.fetch(candidate.ref, []).last)
        end.map(&:ref)
      end

      def siblings_for(task, tasks)
        Array(tasks).select do |candidate|
          candidate.ref != task.ref && candidate.parent_ref == task.parent_ref
        end
      end

      def latest_run_verification_blocked?(run)
        return false unless run&.terminal_outcome == :blocked

        diagnosis = run.phase_records.reverse_each.find { |record| !record.blocked_diagnosis.nil? }&.blocked_diagnosis
        diagnosis&.error_category == "verification_failed"
      end

      def healthy_assessment
        Assessment.new(healthy: true, reason: :healthy, blocking_task_refs: [].freeze)
      end
    end
  end
end
