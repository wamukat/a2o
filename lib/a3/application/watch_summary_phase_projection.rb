# frozen_string_literal: true

module A3
  module Application
    class WatchSummaryPhaseProjection
      PHASE_ORDER = %w[implementation review inspection merge].freeze
      PhaseRecord = Struct.new(:phase, :terminal_outcome, keyword_init: true)
      Result = Struct.new(:phase_counts, :phase_states, keyword_init: true)

      def self.call(records:, latest_phase:)
        new(records: records, latest_phase: latest_phase).call
      end

      def initialize(records:, latest_phase:)
        @records = Array(records)
        @latest_phase = latest_phase
      end

      def call
        Result.new(
          phase_counts: phase_counts.freeze,
          phase_states: phase_states.freeze
        )
      end

      private

      attr_reader :records, :latest_phase

      def phase_counts
        visible_records.each_with_object(Hash.new(0)) do |record, counts|
          counts[record.phase] += 1
        end
      end

      def phase_states
        visible_records.each_with_object({}) do |record, states|
          states[record.phase] = state_for(record)
        end
      end

      def visible_records
        records.select { |record| visible_phase?(record.phase) }
      end

      def visible_phase?(phase)
        phase_index = phase_order_index(phase)
        return false unless phase_index
        return true unless latest_phase_index

        phase_index <= latest_phase_index
      end

      def latest_phase_index
        @latest_phase_index ||= phase_order_index(latest_phase)
      end

      def phase_order_index(phase)
        PHASE_ORDER.index(phase.to_s)
      end

      def state_for(record)
        return :failed if record.phase == "review" && record.terminal_outcome&.to_sym == :rework

        :done
      end
    end
  end
end
