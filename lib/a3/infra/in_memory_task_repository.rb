# frozen_string_literal: true

module A3
  module Infra
    class InMemoryTaskRepository
      include A3::Domain::TaskRepository

      def initialize
        @tasks = {}
      end

      def save(task)
        @tasks[task.ref] = task
      end

      def fetch(task_ref)
        @tasks.fetch(task_ref)
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Task not found: #{task_ref}"
      end

      def all
        @tasks.values.sort_by(&:ref).freeze
      end

      def delete(task_ref)
        @tasks.delete(task_ref)
      end
    end
  end
end
