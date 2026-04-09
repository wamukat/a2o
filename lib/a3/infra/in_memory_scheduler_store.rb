# frozen_string_literal: true

module A3
  module Infra
    class InMemorySchedulerStore
      def initialize(state: A3::Domain::SchedulerState.new, cycles: [])
        @state = state
        @cycles = Array(cycles).freeze
      end

      def fetch_state
        @state
      end

      def save_state(state)
        @state = state
      end

      def all_cycles
        @cycles
      end

      def append_cycle(cycle)
        stored_cycle = cycle.cycle_number ? cycle : cycle.with_cycle_number(next_cycle_number)
        @cycles = (@cycles + [stored_cycle]).freeze
        stored_cycle
      end

      def record_cycle_result(next_state:, cycle:)
        stored_cycle = cycle.cycle_number ? cycle : cycle.with_cycle_number(next_cycle_number)
        @state = next_state
        @cycles = (@cycles + [stored_cycle]).freeze
        stored_cycle
      end

      private

      def next_cycle_number
        @cycles.size + 1
      end
    end
  end
end
