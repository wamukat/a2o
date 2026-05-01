# frozen_string_literal: true

module A3
  module Domain
    class ProjectSchedulerConfig
      attr_reader :max_parallel_tasks

      def self.default
        new(max_parallel_tasks: 1)
      end

      def self.from_project_config(payload)
        return default if payload.nil?

        unless payload.is_a?(Hash)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.scheduler must be a mapping"
        end

        max_parallel_tasks = payload.fetch("max_parallel_tasks", 1)
        unless max_parallel_tasks.is_a?(Integer)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.scheduler.max_parallel_tasks must be an integer"
        end
        if max_parallel_tasks < 1
          raise A3::Domain::ConfigurationError, "project.yaml runtime.scheduler.max_parallel_tasks must be greater than or equal to 1"
        end

        new(max_parallel_tasks: max_parallel_tasks)
      end

      def initialize(max_parallel_tasks:)
        @max_parallel_tasks = Integer(max_parallel_tasks)
        freeze
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.max_parallel_tasks == max_parallel_tasks
      end
      alias eql? ==
    end
  end
end
