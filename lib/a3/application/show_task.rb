# frozen_string_literal: true

module A3
  module Application
    class ShowTask
      def initialize(task_repository:, run_repository: nil)
        @task_repository = task_repository
        @run_repository = run_repository
      end

      def call(task_ref:)
        task = @task_repository.fetch(task_ref)
        A3::Domain::OperatorInspectionReadModel::TaskView.from_task(
          task: task,
          tasks: @task_repository.all,
          skill_feedback: latest_skill_feedback(task)
        )
      end

      private

      def latest_skill_feedback(task)
        return [] unless @run_repository && task.current_run_ref

        run = @run_repository.fetch(task.current_run_ref)
        run.phase_records.flat_map do |record|
          Array(record.execution_record&.skill_feedback)
        end
      rescue A3::Domain::RecordNotFound
        []
      end
    end
  end
end
