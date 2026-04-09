# frozen_string_literal: true

module A3
  module Domain
    class SchedulerState
      attr_reader :paused, :last_stop_reason, :last_executed_count

      def initialize(paused: false, last_stop_reason: nil, last_executed_count: 0)
        @paused = paused
        @last_stop_reason = last_stop_reason&.to_sym
        @last_executed_count = Integer(last_executed_count)
        freeze
      end

      def pause
        self.class.new(
          paused: true,
          last_stop_reason: last_stop_reason,
          last_executed_count: last_executed_count
        )
      end

      def resume
        self.class.new(
          paused: false,
          last_stop_reason: last_stop_reason,
          last_executed_count: last_executed_count
        )
      end

      def record_cycle(stop_reason:, executed_count:)
        self.class.new(
          paused: paused,
          last_stop_reason: stop_reason,
          last_executed_count: executed_count
        )
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.paused == paused &&
          other.last_stop_reason == last_stop_reason &&
          other.last_executed_count == last_executed_count
      end
      alias eql? ==
    end
  end
end
