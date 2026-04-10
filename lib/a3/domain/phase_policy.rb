# frozen_string_literal: true

module A3
  module Domain
    class PhasePolicy
      SUPPORTED_PHASES = {
        single: %i[implementation verification merge].freeze,
        child: %i[implementation verification merge].freeze,
        parent: %i[review verification merge].freeze
      }.freeze

      LEGACY_REENTRY_PHASES = {
        single: %i[review].freeze,
        child: %i[review].freeze,
        parent: [].freeze
      }.freeze

      NEXT_PHASE_BY_KIND = {
        single: {
          implementation: :verification,
          review: :verification,
          verification: :merge
        }.freeze,
        child: {
          implementation: :verification,
          review: :verification,
          verification: :merge
        }.freeze,
        parent: {
          review: :verification,
          verification: :merge
        }.freeze
      }.freeze

      STATUS_BY_PHASE = {
        implementation: :in_progress,
        review: :in_review,
        verification: :verifying,
        merge: :merging
      }.freeze

      def initialize(task_kind:, current_status:)
        @task_kind = task_kind.to_sym
        @current_status = current_status.to_sym
      end

      def supports_phase?(phase)
        phase_name = phase.to_sym
        SUPPORTED_PHASES.fetch(@task_kind).include?(phase_name) || legacy_reentry_phase?(phase_name)
      end

      def next_phase_for(phase)
        NEXT_PHASE_BY_KIND.fetch(@task_kind).fetch(phase.to_sym, nil)
      end

      def status_for_phase(phase)
        STATUS_BY_PHASE.fetch(phase.to_sym)
      end

      def terminal_status_for(phase:, outcome:)
        outcome_name = outcome.to_sym
        return :blocked if outcome_name == :blocked
        return @task_kind == :parent ? :blocked : :in_progress if outcome_name == :rework
        return @current_status if %i[retryable terminal_noop].include?(outcome_name)
        return :done if phase.to_sym == :merge

        :done
      end

      private

      def legacy_reentry_phase?(phase_name)
        return false unless @current_status == :in_review

        LEGACY_REENTRY_PHASES.fetch(@task_kind).include?(phase_name)
      end
    end
  end
end
