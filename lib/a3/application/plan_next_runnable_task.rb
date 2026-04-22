# frozen_string_literal: true

require "a3/domain/runnable_task_assessment"

module A3
  module Application
    class PlanNextRunnableTask
      Result = Struct.new(:task, :phase, :selected_assessment, :assessments, keyword_init: true)

      def initialize(task_repository:, sync_external_tasks: nil)
        @task_repository = task_repository
        @sync_external_tasks = sync_external_tasks
      end

      def call
        @sync_external_tasks&.call
        tasks = @task_repository.all
        assessments = tasks.map { |task| A3::Domain::RunnableTaskAssessment.evaluate(task: task, tasks: tasks) }.freeze
        selected_assessment = assessments
          .select(&:runnable?)
          .sort_by { |assessment| [-assessment.task.priority, assessment.task.ref] }
          .first

        Result.new(
          task: selected_assessment&.task,
          phase: selected_assessment&.phase,
          selected_assessment: selected_assessment,
          assessments: assessments
        )
      end
    end
  end
end
