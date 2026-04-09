# frozen_string_literal: true

module A3
  module Domain
    class PhaseSourcePolicy
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
        when :review, :verification, :merge
          task.kind == :parent ? parent_integration_ref_for(task) : work_branch_ref_for(task)
        else
          raise A3::Domain::InvalidPhaseError, "unsupported phase #{phase}"
        end
      end

      def work_branch_ref_for(task)
        "refs/heads/a3/work/#{task.ref.tr('#', '-')}"
      end

      def parent_integration_ref_for(task)
        "refs/heads/a3/parent/#{task.parent_ref&.tr('#', '-') || task.ref.tr('#', '-')}"
      end
    end
  end
end
