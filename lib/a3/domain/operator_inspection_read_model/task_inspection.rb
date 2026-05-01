# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      module TaskInspection
        module_function

        def from_task(task:, tasks:, skill_feedback: [], claim_ref: nil)
          TaskView.from_task(task: task, tasks: tasks, skill_feedback: skill_feedback, claim_ref: claim_ref)
        end
      end
    end
  end
end
