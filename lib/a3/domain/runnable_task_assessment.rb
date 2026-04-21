# frozen_string_literal: true

module A3
  module Domain
    class RunnableTaskAssessment
      attr_reader :task, :phase, :reason, :blocking_task_refs

      def initialize(task:, phase:, reason:, blocking_task_refs: [])
        @task = task
        @phase = phase&.to_sym
        @reason = reason.to_sym
        @blocking_task_refs = Array(blocking_task_refs).freeze
        freeze
      end

      def self.evaluate(task:, tasks:)
        phase = task.runnable_phase
        return new(task: task, phase: nil, reason: :already_running, blocking_task_refs: [task.current_run_ref]) if task.current_run_ref
        return new(task: task, phase: nil, reason: :not_runnable_status) unless phase

        if upstream_parent_line_blocked?(task, tasks, phase)
          return new(
            task: task,
            phase: phase,
            reason: :upstream_unhealthy,
            blocking_task_refs: sibling_blocked_refs(task, tasks)
          )
        end

        if sibling_running?(task, tasks)
          return new(
            task: task,
            phase: phase,
            reason: :sibling_running,
            blocking_task_refs: sibling_running_refs(task, tasks)
          )
        end

        if parent_waiting_for_children?(task, tasks)
          return new(
            task: task,
            phase: phase,
            reason: :parent_waiting_for_children,
            blocking_task_refs: pending_child_refs(task, tasks)
          )
        end

        new(task: task, phase: phase, reason: :runnable)
      end

      def runnable?
        reason == :runnable
      end

      def task_ref
        task.ref
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.task == task &&
          other.phase == phase &&
          other.reason == reason &&
          other.blocking_task_refs == blocking_task_refs
      end
      alias eql? ==

      class << self
        private

        def sibling_running?(task, tasks)
          return false unless task.kind == :child
          return false unless task.parent_ref

          siblings_for(task, tasks).any? { |candidate| !candidate.current_run_ref.nil? }
        end

        def upstream_parent_line_blocked?(task, tasks, phase)
          return false unless task.kind == :child
          return false unless task.parent_ref
          return false unless phase.to_sym == :implementation

          sibling_blocked_refs(task, tasks).any?
        end

        def sibling_running_refs(task, tasks)
          siblings_for(task, tasks).select { |candidate| !candidate.current_run_ref.nil? }.map(&:ref).freeze
        end

        def sibling_blocked_refs(task, tasks)
          siblings_for(task, tasks).select { |candidate| candidate.status == :blocked }.map(&:ref).freeze
        end

        def parent_waiting_for_children?(task, tasks)
          return false unless task.kind == :parent

          pending_child_refs(task, tasks).any?
        end

        def pending_child_refs(task, tasks)
          task.child_refs.select do |child_ref|
            child = find_task(tasks, child_ref)
            child.nil? || child.status != :done
          end.freeze
        end

        def siblings_for(task, tasks)
          tasks.select do |candidate|
            candidate.ref != task.ref &&
              candidate.parent_ref == task.parent_ref
          end
        end

        def find_task(tasks, ref)
          tasks.find { |candidate| candidate.ref == ref }
        end
      end
    end
  end
end
