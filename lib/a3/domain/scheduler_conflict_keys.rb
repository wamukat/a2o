# frozen_string_literal: true

module A3
  module Domain
    class SchedulerConflictKeys
      attr_reader :task_key, :parent_group_key

      def initialize(task_key:, parent_group_key:)
        @task_key = task_key
        @parent_group_key = parent_group_key
        freeze
      end

      def self.for_task(task:, tasks:)
        new(
          task_key: "task:#{task.ref}",
          parent_group_key: parent_group_key_for(task: task, task_index: task_index(tasks))
        )
      end

      def self.parent_group_key_for(task:, task_index:)
        case task.kind
        when :parent
          "parent-group:#{task.ref}"
        when :child
          "parent-group:#{topmost_parent_ref(task: task, task_index: task_index) || task.parent_ref || task.ref}"
        else
          "single:#{task.ref}"
        end
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.task_key == task_key &&
          other.parent_group_key == parent_group_key
      end
      alias eql? ==

      class << self
        private

        def task_index(tasks)
          tasks.each_with_object({}) { |task, memo| memo[task.ref] = task }
        end

        def topmost_parent_ref(task:, task_index:)
          current = task
          seen_refs = {}

          while current.parent_ref
            break if seen_refs[current.parent_ref]

            seen_refs[current.parent_ref] = true
            parent = task_index[current.parent_ref]
            return current.parent_ref unless parent

            current = parent
          end

          current.ref unless current.ref == task.ref
        end
      end
    end
  end
end
