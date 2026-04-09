# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class SchedulerStateView
        attr_reader :paused, :last_stop_reason, :last_executed_count, :status_label, :last_cycle_summary

        def initialize(paused:, last_stop_reason:, last_executed_count:, status_label:, last_cycle_summary:)
          @paused = !!paused
          @last_stop_reason = last_stop_reason&.to_sym
          @last_executed_count = Integer(last_executed_count)
          @status_label = status_label.to_sym
          @last_cycle_summary = last_cycle_summary
          freeze
        end

        def self.from_state(state)
          new(
            paused: state.paused,
            last_stop_reason: state.last_stop_reason,
            last_executed_count: state.last_executed_count,
            status_label: state.paused ? :paused : :active,
            last_cycle_summary: build_last_cycle_summary(state)
          )
        end

        def active?
          !paused
        end

        private_class_method def self.build_last_cycle_summary(state)
          return "no cycles recorded" if state.last_stop_reason.nil?

          "stop_reason=#{state.last_stop_reason} executed_count=#{state.last_executed_count}"
        end
      end
    end
  end
end
