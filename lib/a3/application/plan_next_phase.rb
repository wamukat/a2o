# frozen_string_literal: true

module A3
  module Application
    class PlanNextPhase
      Result = Struct.new(:next_phase, :terminal_status, keyword_init: true)

      def call(task:, run:, outcome:)
        outcome_name = outcome.to_sym
        return Result.new(next_phase: :verification, terminal_status: nil) if outcome_name == :verification_required
        return Result.new(next_phase: nil, terminal_status: task.terminal_status_for(phase: run.phase, outcome: outcome_name)) if outcome_name == :rework

        if %i[blocked retryable terminal_noop].include?(outcome_name)
          return Result.new(next_phase: nil, terminal_status: task.terminal_status_for(phase: run.phase, outcome: outcome_name))
        end

        next_phase = task.next_phase_for(run.phase)
        return Result.new(next_phase: nil, terminal_status: task.terminal_status_for(phase: run.phase, outcome: outcome_name)) unless next_phase

        Result.new(next_phase: next_phase, terminal_status: nil)
      end
    end
  end
end
