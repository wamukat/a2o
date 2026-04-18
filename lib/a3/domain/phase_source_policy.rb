# frozen_string_literal: true

module A3
  module Domain
    class PhaseSourcePolicy
      def initialize(branch_namespace: ENV.fetch("A2O_BRANCH_NAMESPACE", ENV.fetch("A3_BRANCH_NAMESPACE", nil)))
        @branch_namespace = normalize_branch_namespace(branch_namespace)
      end

      def source_descriptor_for(task:, phase:)
        ref = source_ref_for(task: task, phase: phase)

        A3::Domain::SourceDescriptor.for_phase(task: task, phase: phase, ref: ref)
      end

      def review_target_for(task:, phase:, source_ref:)
        A3::Domain::ReviewTarget.new(
          base_commit: source_ref,
          head_commit: source_ref,
          task_ref: task.ref,
          phase_ref: phase
        )
      end

      private

      def source_ref_for(task:, phase:)
        case phase.to_sym
        when :implementation
          work_branch_ref_for(task)
        when :verification
          task.verification_source_ref || (task.kind == :parent ? parent_integration_ref_for(task) : work_branch_ref_for(task))
        when :review, :merge
          task.kind == :parent ? parent_integration_ref_for(task) : work_branch_ref_for(task)
        else
          raise A3::Domain::InvalidPhaseError, "unsupported phase #{phase}"
        end
      end

      def work_branch_ref_for(task)
        branch_ref("work", task.ref)
      end

      def parent_integration_ref_for(task)
        branch_ref("parent", task.parent_ref || task.ref)
      end

      def branch_ref(kind, task_ref)
        parts = ["refs/heads/a2o"]
        parts << @branch_namespace if @branch_namespace
        parts << kind
        parts << task_ref.tr("#", "-")
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
