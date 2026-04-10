# frozen_string_literal: true

require_relative "../task_phase_projection"

module A3
  module Domain
    class OperatorInspectionReadModel
      class TaskRelation
        attr_reader :ref, :status, :current_run_ref

        def initialize(ref:, status:, current_run_ref:)
          @ref = ref
          @status = status.to_sym
          @current_run_ref = current_run_ref
          freeze
        end

        def self.from_task(task)
          return nil unless task

          new(
            ref: task.ref,
            status: A3::Domain::TaskPhaseProjection.status_for(task_kind: task.kind, status: task.status),
            current_run_ref: task.current_run_ref
          )
        end

        def self.missing(task_ref)
          new(ref: task_ref, status: :missing, current_run_ref: nil)
        end

        def ==(other)
          other.is_a?(self.class) &&
            other.ref == ref &&
            other.status == status &&
            other.current_run_ref == current_run_ref
        end
        alias eql? ==
      end
    end
  end
end
