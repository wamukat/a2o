# frozen_string_literal: true

module A3
  module Domain
    class UpstreamLineGuard
      def initialize(branch_namespace: ENV.fetch("A2O_BRANCH_NAMESPACE", ENV.fetch("A3_BRANCH_NAMESPACE", nil)))
        @branch_namespace = normalize_branch_namespace(branch_namespace)
      end

      Assessment = Struct.new(:healthy, :reason, :blocking_task_refs, keyword_init: true) do
        def healthy?
          !!healthy
        end
      end

      def evaluate(task:, phase:, tasks:, runs:, source_ref: nil)
        return healthy_assessment unless child_phase_guarded?(task, phase, source_ref)

        blocked_refs = verification_blocked_sibling_refs(task, tasks, runs)
        return healthy_assessment if blocked_refs.empty?

        Assessment.new(
          healthy: false,
          reason: :upstream_unhealthy,
          blocking_task_refs: blocked_refs.freeze
        )
      end

      private

      def child_phase_guarded?(task, phase, source_ref)
        return false unless task.kind == :child
        return false if task.parent_ref.to_s.empty?
        return false if phase.nil?
        return true if phase.to_sym == :implementation

        phase.to_sym == :verification && source_ref == parent_integration_ref_for(task.parent_ref)
      end

      def verification_blocked_sibling_refs(task, tasks, runs)
        runs_by_task = Array(runs).group_by(&:task_ref)
        siblings_for(task, tasks).select do |candidate|
          candidate.status == :blocked && latest_run_verification_blocked?(candidate, runs_by_task.fetch(candidate.ref, []).last)
        end.map(&:ref)
      end

      def siblings_for(task, tasks)
        Array(tasks).select do |candidate|
          candidate.ref != task.ref && candidate.parent_ref == task.parent_ref
        end
      end

      def latest_run_verification_blocked?(task, run)
        return false unless run&.terminal_outcome == :blocked

        diagnosis = run.phase_records.reverse_each.find { |record| !record.blocked_diagnosis.nil? }&.blocked_diagnosis
        return false unless diagnosis&.error_category == "verification_failed"

        run.source_descriptor.ref == parent_integration_ref_for(task.parent_ref)
      end

      def healthy_assessment
        Assessment.new(healthy: true, reason: :healthy, blocking_task_refs: [].freeze)
      end

      def parent_integration_ref_for(parent_ref)
        parts = ["refs/heads/a2o"]
        parts << @branch_namespace if @branch_namespace
        parts << "parent"
        parts << parent_ref.to_s.tr("#", "-")
        parts.join("/")
      end

      def normalize_branch_namespace(value)
        normalized = value.to_s.strip.gsub(%r{[^A-Za-z0-9._/-]}, "-").gsub(%r{/+}, "/").gsub(%r{\A/+|/+\z}, "")
        normalized = normalized.split("/").map { |part| part.sub(/\Aa3(?:-|\z)/, "") }.reject(&:empty?).join("/")
        normalized.empty? ? nil : normalized
      end
    end
  end
end
