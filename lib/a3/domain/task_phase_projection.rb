# frozen_string_literal: true

module A3
  module Domain
    module TaskPhaseProjection
      module_function

      def status_for(task_kind:, status:)
        status_name = status.to_sym
        return :verifying if status_name == :in_review && task_kind.to_sym != :parent

        status_name
      end

      def phase_for(task_kind:, phase:)
        phase_name = phase.to_sym
        return :verification if phase_name == :review && task_kind.to_sym != :parent

        phase_name
      end
    end
  end
end
