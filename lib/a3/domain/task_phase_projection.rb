# frozen_string_literal: true

module A3
  module Domain
    module TaskPhaseProjection
      module_function

      def status_for(task_kind:, status:)
        status.to_sym
      end

      def phase_for(task_kind:, phase:)
        phase.to_sym
      end
    end
  end
end
