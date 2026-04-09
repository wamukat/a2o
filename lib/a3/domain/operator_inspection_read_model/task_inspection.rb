# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      module TaskInspection
        module_function

        def from_task(task:, tasks:)
          TaskView.from_task(task: task, tasks: tasks)
        end
      end
    end
  end
end
