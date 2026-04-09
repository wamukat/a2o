# frozen_string_literal: true

module A3
  module Application
    class ShowTask
      def initialize(task_repository:)
        @task_repository = task_repository
      end

      def call(task_ref:)
        task = @task_repository.fetch(task_ref)
        A3::Domain::OperatorInspectionReadModel::TaskView.from_task(
          task: task,
          tasks: @task_repository.all
        )
      end
    end
  end
end
