# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      module TaskInspection
        module_function

        def from_task(task:, tasks:, skill_feedback: [])
          TaskView.from_task(task: task, tasks: tasks, skill_feedback: skill_feedback)
        end
      end
    end
  end
end
