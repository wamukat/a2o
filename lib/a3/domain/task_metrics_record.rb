# frozen_string_literal: true

module A3
  module Domain
    class TaskMetricsRecord
      SECTIONS = %w[code_changes tests coverage timing cost custom].freeze
      PROJECT_METADATA_KEYS = %w[project_key task_ref parent_ref timestamp].freeze

      attr_reader :project_key, :task_ref, :parent_ref, :timestamp, :code_changes, :tests, :coverage, :timing, :cost, :custom

      def initialize(task_ref:, timestamp:, parent_ref: nil, project_key: A3::Domain::ProjectIdentity.current, code_changes: {}, tests: {}, coverage: {}, timing: {}, cost: {}, custom: {})
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @task_ref = required_string(task_ref, "task_ref")
        @parent_ref = optional_string(parent_ref, "parent_ref")
        @timestamp = required_string(timestamp, "timestamp")
        @code_changes = normalize_section(code_changes, "code_changes")
        @tests = normalize_section(tests, "tests")
        @coverage = normalize_section(coverage, "coverage")
        @timing = normalize_section(timing, "timing")
        @cost = normalize_section(cost, "cost")
        @custom = normalize_section(custom, "custom")
        freeze
      end

      def self.from_project_metrics(payload:, task_ref: nil, timestamp: nil, parent_ref: nil, project_key: A3::Domain::ProjectIdentity.current, timing: {}, cost: {})
        raise ArgumentError, "task metrics payload must be a JSON object" unless payload.is_a?(Hash)

        unknown_sections = payload.keys.map(&:to_s) - SECTIONS - PROJECT_METADATA_KEYS
        raise ArgumentError, "task metrics payload contains unsupported section(s): #{unknown_sections.join(', ')}" unless unknown_sections.empty?

        resolved_task_ref = resolve_payload_metadata(payload, "task_ref", task_ref)
        resolved_project_key = resolve_payload_metadata(payload, "project_key", project_key)
        resolved_parent_ref = resolve_payload_metadata(payload, "parent_ref", parent_ref)
        resolved_timestamp = resolve_payload_metadata(payload, "timestamp", timestamp)
        new(
          task_ref: resolved_task_ref,
          project_key: resolved_project_key,
          parent_ref: resolved_parent_ref,
          timestamp: resolved_timestamp,
          code_changes: payload.fetch("code_changes", payload.fetch(:code_changes, {})),
          tests: payload.fetch("tests", payload.fetch(:tests, {})),
          coverage: payload.fetch("coverage", payload.fetch(:coverage, {})),
          timing: section_from_payload_or_runtime(payload, "timing", timing),
          cost: section_from_payload_or_runtime(payload, "cost", cost),
          custom: payload.fetch("custom", payload.fetch(:custom, {}))
        )
      end

      def self.from_persisted_form(record)
        raise ArgumentError, "task metrics record must be a Hash" unless record.is_a?(Hash)

        A3::Domain::ProjectIdentity.require_readable!(project_key: record["project_key"], record_type: "task metrics")
        new(
          task_ref: record.fetch("task_ref"),
          project_key: record["project_key"],
          parent_ref: record["parent_ref"],
          timestamp: record.fetch("timestamp"),
          code_changes: record.fetch("code_changes", {}),
          tests: record.fetch("tests", {}),
          coverage: record.fetch("coverage", {}),
          timing: record.fetch("timing", {}),
          cost: record.fetch("cost", {}),
          custom: record.fetch("custom", {})
        )
      end

      def self.resolve_payload_metadata(payload, field, expected)
        payload_value = payload.fetch(field, payload.fetch(field.to_sym, nil))
        return expected if payload_value.nil?
        return payload_value if expected.nil? || expected.to_s == payload_value.to_s

        raise ArgumentError, "task metrics #{field} does not match runtime task context"
      end

      def self.section_from_payload_or_runtime(payload, field, runtime_value)
        return runtime_value unless runtime_value.empty?

        payload.fetch(field, payload.fetch(field.to_sym, {}))
      end

      def persisted_form
        {
          "task_ref" => task_ref,
          "project_key" => project_key,
          "parent_ref" => parent_ref,
          "timestamp" => timestamp,
          "code_changes" => code_changes,
          "tests" => tests,
          "coverage" => coverage,
          "timing" => timing,
          "cost" => cost,
          "custom" => custom
        }.compact
      end

      def ==(other)
        other.is_a?(self.class) && other.persisted_form == persisted_form
      end

      private

      def required_string(value, field)
        normalized = value.to_s.strip
        raise ArgumentError, "task metrics #{field} is required" if normalized.empty?

        normalized.freeze
      end

      def optional_string(value, field)
        return nil if value.nil?

        normalized = value.to_s.strip
        raise ArgumentError, "task metrics #{field} must not be blank when provided" if normalized.empty?

        normalized.freeze
      end

      def normalize_section(value, section)
        raise ArgumentError, "task metrics #{section} must be a JSON object" unless value.is_a?(Hash)

        deep_freeze(stringify_keys(value))
      end

      def stringify_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            result[key.to_s] = stringify_keys(child)
          end
        when Array
          value.map { |child| stringify_keys(child) }
        else
          value
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each_value { |child| deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end
    end
  end
end
