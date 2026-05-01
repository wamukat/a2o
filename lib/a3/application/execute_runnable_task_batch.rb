# frozen_string_literal: true

require "securerandom"
require "time"

module A3
  module Application
    class ExecuteRunnableTaskBatch
      Result = Struct.new(:executions, :batch_plan, keyword_init: true) do
        def empty?
          executions.empty?
        end

        def idle?
          empty? && batch_plan.idle?
        end

        def busy?
          empty? && batch_plan.busy?
        end

        def waiting?
          empty? && batch_plan.waiting?
        end
      end

      def initialize(
        plan_runnable_task_batch:,
        schedule_next_run:,
        task_claim_repository:,
        run_repository:,
        run_worker_phase:,
        run_verification:,
        run_merge:,
        claimed_by: nil,
        clock: -> { Time.now.utc }
      )
        @plan_runnable_task_batch = plan_runnable_task_batch
        @schedule_next_run = schedule_next_run
        @task_claim_repository = task_claim_repository
        @run_repository = run_repository
        @run_worker_phase = run_worker_phase
        @run_verification = run_verification
        @run_merge = run_merge
        @claimed_by = claimed_by || "scheduler:#{$$}:#{SecureRandom.hex(4)}"
        @clock = clock
      end

      def call(project_context:, max_steps:)
        batch_plan = @plan_runnable_task_batch.call(
          max_parallel_tasks: project_context.surface.scheduler_config.max_parallel_tasks
        )
        candidates = batch_plan.candidates.first(Integer(max_steps))
        work_items = candidates.filter_map do |candidate|
          prepare_work_item(project_context: project_context, candidate: candidate)
        end
        Result.new(
          executions: execute_work_items(project_context: project_context, work_items: work_items),
          batch_plan: batch_plan
        )
      end

      private

      WorkItem = Struct.new(:task, :phase, :started_run, :claim, keyword_init: true)

      def prepare_work_item(project_context:, candidate:)
        return nil unless @schedule_next_run.schedulable_candidate?(task: candidate.task, phase: candidate.phase)

        claim = @task_claim_repository.claim_task(
          task_ref: candidate.task.ref,
          phase: candidate.phase,
          parent_group_key: candidate.conflict_keys.parent_group_key,
          claimed_by: @claimed_by,
          claimed_at: @clock.call.iso8601
        )
        scheduled = @schedule_next_run.schedule_candidate(
          project_context: project_context,
          task: candidate.task,
          phase: candidate.phase
        )
        unless scheduled.task
          @task_claim_repository.release_claim(claim_ref: claim.claim_ref)
          return nil
        end

        linked_claim = @task_claim_repository.link_run(
          claim_ref: claim.claim_ref,
          run_ref: scheduled.started_run.run.ref
        )
        WorkItem.new(
          task: scheduled.task,
          phase: scheduled.phase,
          started_run: scheduled.started_run,
          claim: linked_claim
        )
      rescue A3::Domain::SchedulerTaskClaimConflict
        nil
      rescue StandardError
        @task_claim_repository.release_claim(claim_ref: claim.claim_ref) if defined?(claim) && claim
        raise
      end

      def execute_work_items(project_context:, work_items:)
        threads = work_items.map do |work_item|
          Thread.new do
            begin
              { result: execute_work_item(project_context: project_context, work_item: work_item) }
            rescue StandardError => e
              { error: e }
            end
          end
        end
        outcomes = threads.map(&:value)
        failure = outcomes.find { |outcome| outcome.key?(:error) }
        raise failure.fetch(:error) if failure

        outcomes.map { |outcome| outcome.fetch(:result) }
      end

      def execute_work_item(project_context:, work_item:)
        execution_result = execute_phase(
          task_ref: work_item.task.ref,
          run_ref: work_item.started_run.run.ref,
          phase: work_item.phase,
          project_context: project_context
        )
        A3::Application::ExecuteNextRunnableTask::Result.new(
          task: work_item.task,
          phase: work_item.phase,
          started_run: work_item.started_run,
          execution_result: execution_result
        )
      ensure
        release_terminal_claim(work_item)
      end

      def execute_phase(task_ref:, run_ref:, phase:, project_context:)
        case phase.to_sym
        when :implementation, :review
          @run_worker_phase.call(task_ref: task_ref, run_ref: run_ref, project_context: project_context)
        when :verification
          @run_verification.call(task_ref: task_ref, run_ref: run_ref, project_context: project_context)
        when :merge
          @run_merge.call(task_ref: task_ref, run_ref: run_ref, project_context: project_context)
        else
          raise A3::Domain::InvalidPhaseError, "unsupported phase #{phase}"
        end
      end

      def release_terminal_claim(work_item)
        run_ref = work_item.started_run.run.ref
        run = @run_repository.fetch(run_ref)
        return unless run.terminal?

        @task_claim_repository.release_claim(
          claim_ref: work_item.claim.claim_ref,
          run_ref: run_ref
        )
      rescue A3::Domain::RecordNotFound
        nil
      end
    end
  end
end
