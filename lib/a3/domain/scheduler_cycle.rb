# frozen_string_literal: true

module A3
  module Domain
    class SchedulerCycle
      attr_reader :cycle_number, :executed_count, :executed_steps, :idle_reached, :stop_reason, :quarantined_count, :project_key

      def initialize(cycle_number: nil, executed_count:, executed_steps: [], idle_reached:, stop_reason:, quarantined_count:, project_key: A3::Domain::ProjectIdentity.current)
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @cycle_number = cycle_number.nil? ? nil : Integer(cycle_number)
        @executed_count = Integer(executed_count)
        @executed_steps = Array(executed_steps).freeze
        @idle_reached = !!idle_reached
        @stop_reason = stop_reason&.to_sym
        @quarantined_count = Integer(quarantined_count)
        freeze
      end

      def self.from_execute_until_idle_result(result, cycle_number: nil, project_key: A3::Domain::ProjectIdentity.current)
        new(
          cycle_number: cycle_number,
          project_key: project_key,
          executed_count: result.executed_count,
          executed_steps: result.executions.map { |execution| SchedulerCycleStep.from_execution(execution) },
          idle_reached: result.idle_reached,
          stop_reason: result.stop_reason,
          quarantined_count: result.quarantined_count
        )
      end

      def self.from_persisted_form(record)
        A3::Domain::ProjectIdentity.require_readable!(project_key: record["project_key"], record_type: "scheduler cycle")
        new(
          cycle_number: record["cycle_number"],
          project_key: record["project_key"],
          executed_count: record.fetch("executed_count"),
          executed_steps: record.fetch("executed_steps", []).map { |step| SchedulerCycleStep.from_persisted_form(step) },
          idle_reached: record.fetch("idle_reached"),
          stop_reason: record["stop_reason"],
          quarantined_count: record.fetch("quarantined_count")
        )
      end

      def persisted_form
        {
          "cycle_number" => cycle_number,
          "project_key" => project_key,
          "executed_count" => executed_count,
          "executed_steps" => executed_steps.map(&:persisted_form),
          "idle_reached" => idle_reached,
          "stop_reason" => stop_reason&.to_s,
          "quarantined_count" => quarantined_count
        }.compact
      end

      def with_cycle_number(cycle_number)
        self.class.new(
          cycle_number: cycle_number,
          project_key: project_key,
          executed_count: executed_count,
          executed_steps: executed_steps,
          idle_reached: idle_reached,
          stop_reason: stop_reason,
          quarantined_count: quarantined_count
        )
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.cycle_number == cycle_number &&
          other.project_key == project_key &&
          other.executed_count == executed_count &&
          other.executed_steps == executed_steps &&
          other.idle_reached == idle_reached &&
          other.stop_reason == stop_reason &&
          other.quarantined_count == quarantined_count
      end
      alias eql? ==
    end
  end
end
