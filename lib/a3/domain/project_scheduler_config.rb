# frozen_string_literal: true

module A3
  module Domain
    class ProjectSchedulerConfig
      attr_reader :max_parallel_tasks, :max_consecutive_rework_without_commit

      def self.default
        new(max_parallel_tasks: 1, max_consecutive_rework_without_commit: 3)
      end

      def self.from_project_config(payload = nil, runtime: nil, **keyword_payload)
        payload = keyword_payload unless keyword_payload.empty?
        runtime_payload = runtime || {}
        root_threshold = runtime_payload.is_a?(Hash) ? runtime_payload.fetch("max_consecutive_rework_without_commit", nil) : nil
        return new(max_parallel_tasks: 1, max_consecutive_rework_without_commit: normalize_no_commit_rework_limit(root_threshold)) if payload.nil?

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

        new(max_parallel_tasks: max_parallel_tasks, max_consecutive_rework_without_commit: normalize_no_commit_rework_limit(root_threshold))
      end

      def initialize(max_parallel_tasks:, max_consecutive_rework_without_commit: 3)
        @max_parallel_tasks = Integer(max_parallel_tasks)
        @max_consecutive_rework_without_commit = Integer(max_consecutive_rework_without_commit)
        freeze
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.max_parallel_tasks == max_parallel_tasks &&
          other.max_consecutive_rework_without_commit == max_consecutive_rework_without_commit
      end
      alias eql? ==

      def self.normalize_no_commit_rework_limit(value)
        limit = value.nil? ? 3 : value
        unless limit.is_a?(Integer)
          raise A3::Domain::ConfigurationError, "project.yaml runtime.max_consecutive_rework_without_commit must be an integer"
        end
        if limit < 1
          raise A3::Domain::ConfigurationError, "project.yaml runtime.max_consecutive_rework_without_commit must be greater than or equal to 1"
        end

        limit
      end
      private_class_method :normalize_no_commit_rework_limit
    end
  end
end
