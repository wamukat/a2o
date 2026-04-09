# frozen_string_literal: true

module A3
  module Domain
    class ReviewTarget
      attr_reader :base_commit, :head_commit, :task_ref, :phase_ref

      def initialize(base_commit:, head_commit:, task_ref:, phase_ref:)
        @base_commit = base_commit
        @head_commit = head_commit
        @task_ref = task_ref
        @phase_ref = phase_ref.to_sym
        freeze
      end

      def self.from_persisted_form(record)
        return nil unless record

        new(
          base_commit: record.fetch("base_commit"),
          head_commit: record.fetch("head_commit"),
          task_ref: record.fetch("task_ref"),
          phase_ref: record.fetch("phase_ref")
        )
      end

      def persisted_form
        {
          "base_commit" => base_commit,
          "head_commit" => head_commit,
          "task_ref" => task_ref,
          "phase_ref" => phase_ref.to_s
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.base_commit == base_commit &&
          other.head_commit == head_commit &&
          other.task_ref == task_ref &&
          other.phase_ref == phase_ref
      end
      alias eql? ==
    end
  end
end
