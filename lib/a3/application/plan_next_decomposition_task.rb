# frozen_string_literal: true

require "a3/domain/scheduler_selection_policy"

module A3
  module Application
    class PlanNextDecompositionTask
      ACTIVE_STATUSES = %i[in_progress in_review verifying merging].freeze

      Result = Struct.new(:task, :active_task, :candidates, keyword_init: true)

      def initialize(task_repository:, sync_external_tasks: nil, scheduler_selection_policy: A3::Domain::SchedulerSelectionPolicy.new)
        @task_repository = task_repository
        @sync_external_tasks = sync_external_tasks
        @scheduler_selection_policy = scheduler_selection_policy
      end

      def call
        @sync_external_tasks&.call
        tasks = @task_repository.all
        candidates = tasks.select { |task| task.decomposition_requested? && !task.decomposed? }.freeze
        active_task = candidates.find { |task| active_decomposition_task?(task) }
        selected_task = active_task ? nil : next_candidate(candidates: candidates, tasks: tasks)

        Result.new(
          task: selected_task,
          active_task: active_task,
          candidates: candidates
        )
      end

      private

      def active_decomposition_task?(task)
        !task.current_run_ref.nil? || ACTIVE_STATUSES.include?(task.status)
      end

      def next_candidate(candidates:, tasks:)
        runnable_candidates = candidates.select do |task|
          task.status == :todo && task.current_run_ref.nil?
        end

        @scheduler_selection_policy.sort_assessments(
          assessments: runnable_candidates.map { |task| CandidateAssessment.new(task) },
          tasks: tasks
        ).first&.task
      end

      class CandidateAssessment
        attr_reader :task

        def initialize(task)
          @task = task
        end
      end
    end
  end
end
