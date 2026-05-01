# frozen_string_literal: true

require_relative "../task_phase_projection"

module A3
  module Domain
    class OperatorInspectionReadModel
      class TaskView
        attr_reader :ref, :kind, :status, :current_run_ref, :claim_ref, :edit_scope, :verification_scope, :topology, :runnable_assessment, :skill_feedback, :clarification_request

        def initialize(ref:, kind:, status:, current_run_ref:, claim_ref: nil, edit_scope:, verification_scope:, topology:, runnable_assessment:, skill_feedback: [], clarification_request: nil)
          @ref = ref
          @kind = kind.to_sym
          @status = status.to_sym
          @current_run_ref = current_run_ref
          @claim_ref = claim_ref
          @edit_scope = Array(edit_scope).map(&:to_sym).freeze
          @verification_scope = Array(verification_scope).map(&:to_sym).freeze
          @topology = topology
          @runnable_assessment = runnable_assessment
          @skill_feedback = Array(skill_feedback).freeze
          @clarification_request = clarification_request
          freeze
        end

        def self.from_task(task:, tasks:, skill_feedback: [], clarification_request: nil, claim_ref: nil)
          new(
            ref: task.ref,
            kind: task.kind,
            status: A3::Domain::TaskPhaseProjection.status_for(task_kind: task.kind, status: task.status),
            current_run_ref: task.current_run_ref,
            claim_ref: claim_ref,
            edit_scope: task.edit_scope,
            verification_scope: task.verification_scope,
            topology: TaskTopology.from_task_and_tasks(task: task, tasks: tasks),
            runnable_assessment: RunnableAssessment.from_assessment(
              A3::Domain::RunnableTaskAssessment.evaluate(task: task, tasks: tasks)
            ),
            skill_feedback: skill_feedback,
            clarification_request: clarification_request
          )
        end
      end
    end
  end
end
