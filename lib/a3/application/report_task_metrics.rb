# frozen_string_literal: true

module A3
  module Application
    class ReportTaskMetrics
      SummaryEntry = Struct.new(
        :group_key,
        :record_count,
        :task_count,
        :parent_count,
        :latest_timestamp,
        :lines_added,
        :lines_deleted,
        :files_changed,
        :tests_passed,
        :tests_failed,
        :tests_skipped,
        :latest_line_coverage,
        keyword_init: true
      ) do
        def persisted_form
          {
            "group_key" => group_key,
            "record_count" => record_count,
            "task_count" => task_count,
            "parent_count" => parent_count,
            "latest_timestamp" => latest_timestamp,
            "lines_added" => lines_added,
            "lines_deleted" => lines_deleted,
            "files_changed" => files_changed,
            "tests_passed" => tests_passed,
            "tests_failed" => tests_failed,
            "tests_skipped" => tests_skipped,
            "latest_line_coverage" => latest_line_coverage
          }
        end
      end

      def initialize(task_metrics_repository:)
        @task_metrics_repository = task_metrics_repository
      end

      def list
        @task_metrics_repository.all
      end

      def summary(group_by: :task)
        grouped = list.group_by { |record| group_key_for(record, group_by.to_sym) }
        grouped.keys.sort.map do |key|
          records = grouped.fetch(key)
          latest = records.max_by(&:timestamp)
          SummaryEntry.new(
            group_key: key,
            record_count: records.size,
            task_count: records.map(&:task_ref).uniq.size,
            parent_count: records.map(&:parent_ref).compact.uniq.size,
            latest_timestamp: latest&.timestamp,
            lines_added: sum_section(records, :code_changes, "lines_added"),
            lines_deleted: sum_section(records, :code_changes, "lines_deleted"),
            files_changed: sum_section(records, :code_changes, "files_changed"),
            tests_passed: sum_section(records, :tests, "passed_count"),
            tests_failed: sum_section(records, :tests, "failed_count"),
            tests_skipped: sum_section(records, :tests, "skipped_count"),
            latest_line_coverage: latest_line_coverage(records)
          )
        end
      end

      private

      def group_key_for(record, group_by)
        case group_by
        when :task
          record.task_ref
        when :parent
          record.parent_ref || record.task_ref
        else
          raise ArgumentError, "unsupported metrics summary group_by: #{group_by}"
        end
      end

      def sum_section(records, section, field)
        records.sum { |record| numeric(record.public_send(section).fetch(field, 0)) }
      end

      def latest_line_coverage(records)
        value = records.max_by(&:timestamp)&.coverage&.fetch("line_percent", nil)
        value.nil? ? nil : numeric(value)
      end

      def numeric(value)
        return value if value.is_a?(Numeric)
        return 0 if value.nil? || value.to_s.strip.empty?

        Float(value)
      rescue ArgumentError
        0
      end
    end
  end
end
