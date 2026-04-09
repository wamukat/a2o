# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class TaskView
        attr_reader :ref, :kind, :status, :current_run_ref, :edit_scope, :verification_scope, :topology, :runnable_assessment

        def initialize(ref:, kind:, status:, current_run_ref:, edit_scope:, verification_scope:, topology:, runnable_assessment:)
          @ref = ref
          @kind = kind.to_sym
          @status = status.to_sym
          @current_run_ref = current_run_ref
          @edit_scope = Array(edit_scope).map(&:to_sym).freeze
          @verification_scope = Array(verification_scope).map(&:to_sym).freeze
          @topology = topology
          @runnable_assessment = runnable_assessment
          freeze
        end

        def self.from_task(task:, tasks:)
          new(
            ref: task.ref,
            kind: task.kind,
            status: task.status,
            current_run_ref: task.current_run_ref,
            edit_scope: task.edit_scope,
            verification_scope: task.verification_scope,
            topology: TaskTopology.from_task_and_tasks(task: task, tasks: tasks),
            runnable_assessment: RunnableAssessment.from_assessment(
              A3::Domain::RunnableTaskAssessment.evaluate(task: task, tasks: tasks)
            )
          )
        end
      end
    end
  end
end
