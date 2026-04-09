# frozen_string_literal: true

module A3
  module Domain
    class OperatorInspectionReadModel
      class SchedulerHistory
        class StepView
          attr_reader :task_ref, :phase, :summary

          def initialize(task_ref:, phase:, summary:)
            @task_ref = task_ref
            @phase = phase.to_sym
            @summary = summary
            freeze
          end

          def self.from_step(step)
            new(
              task_ref: step.task_ref,
              phase: step.phase,
              summary: "#{step.task_ref}:#{step.phase}"
            )
          end
        end

        class CycleView
          attr_reader :cycle_number, :executed_count, :executed_steps, :idle_reached, :stop_reason,
                      :quarantined_count, :summary

          def initialize(cycle_number:, executed_count:, executed_steps:, idle_reached:, stop_reason:, quarantined_count:, summary:)
            @cycle_number = cycle_number
            @executed_count = Integer(executed_count)
            @executed_steps = Array(executed_steps).freeze
            @idle_reached = !!idle_reached
            @stop_reason = stop_reason&.to_sym
            @quarantined_count = Integer(quarantined_count)
            @summary = summary
            freeze
          end

          def self.from_cycle(cycle)
            executed_steps = cycle.executed_steps.map { |step| StepView.from_step(step) }

            new(
              cycle_number: cycle.cycle_number,
              executed_count: cycle.executed_count,
              executed_steps: executed_steps,
              idle_reached: cycle.idle_reached,
              stop_reason: cycle.stop_reason,
              quarantined_count: cycle.quarantined_count,
              summary: build_summary(cycle)
            )
          end

          private_class_method def self.build_summary(cycle)
            "cycle=#{cycle.cycle_number} executed=#{cycle.executed_count} idle=#{cycle.idle_reached} stop_reason=#{cycle.stop_reason} quarantined=#{cycle.quarantined_count}"
          end
        end

        include Enumerable

        attr_reader :cycles

        def initialize(cycles:)
          @cycles = Array(cycles).freeze
          freeze
        end

        def self.from_cycles(cycles)
          new(cycles: Array(cycles).map { |cycle| CycleView.from_cycle(cycle) })
        end

        def each(&block)
          cycles.each(&block)
        end

        def empty?
          cycles.empty?
        end

        def size
          cycles.size
        end

        def first
          cycles.first
        end

        def ==(other)
          other.is_a?(self.class) && other.cycles == cycles
        end
        alias eql? ==
      end
    end
  end
end
