# frozen_string_literal: true

module A3
  module Domain
    class SchedulerSelectionPolicy
      def sort_assessments(assessments:, tasks:)
        task_index = tasks.each_with_object({}) { |task, memo| memo[task.ref] = task }

        assessments.sort_by do |assessment|
          selection_sort_key(task: assessment.task, task_index: task_index)
        end
      end

      def selection_sort_key(task:, task_index:)
        group_task = selection_group_task(task: task, task_index: task_index)
        [
          -group_task.priority,
          group_task.ref,
          -task.priority,
          task.ref
        ]
      end

      private

      def selection_group_task(task:, task_index:)
        current = task
        seen_refs = {}

        while current.parent_ref
          break if seen_refs[current.parent_ref]

          seen_refs[current.parent_ref] = true
          parent = task_index[current.parent_ref]
          break unless parent

          current = parent
        end

        current
      end
    end
  end
end
