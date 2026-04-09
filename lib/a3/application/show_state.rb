# frozen_string_literal: true

module A3
  module Application
    class ShowState
      ShotState = Struct.new(:pid, :status, keyword_init: true) do
        def active?
          status == :active
        end

        def stale?
          status == :stale
        end
      end

      ActiveRunView = Struct.new(:task_ref, :run_ref, :phase, :status, keyword_init: true)
      TaskView = Struct.new(:task_ref, :status, :phase, keyword_init: true)
      Result = Struct.new(
        :scheduler_state,
        :shot_state,
        :active_runs,
        :queued_tasks,
        :blocked_tasks,
        :repairable_items,
        keyword_init: true
      )

      def initialize(task_repository:, run_repository:, scheduler_state_repository:, scheduler_cycle_repository:, storage_dir:, execution_process_probe: nil)
        @task_repository = task_repository
        @run_repository = run_repository
        @scheduler_state_repository = scheduler_state_repository
        @scheduler_cycle_repository = scheduler_cycle_repository
        @storage_dir = File.expand_path(storage_dir)
        @execution_process_probe = execution_process_probe || A3::Application::ExecutionProcessProbe.new(storage_dir: @storage_dir)
      end

      def call
        scheduler_state = A3::Domain::OperatorInspectionReadModel::SchedulerStateView.from_state(
          @scheduler_state_repository.fetch
        )
        shot_state = inspect_shot_lock
        runs_by_ref = @run_repository.all.each_with_object({}) { |run, memo| memo[run.ref] = run }
        tasks = @task_repository.all

        active_runs = tasks.each_with_object([]) do |task, memo|
          next unless task.current_run_ref

          run = runs_by_ref[task.current_run_ref]
          memo << ActiveRunView.new(
            task_ref: task.ref,
            run_ref: task.current_run_ref,
            phase: run&.phase,
            status: active_run_status(run, shot_state)
          )
        end

        queued_tasks = tasks.each_with_object([]) do |task, memo|
          next if task.current_run_ref

          phase = task.runnable_phase
          next unless phase

          memo << TaskView.new(task_ref: task.ref, status: task.status, phase: phase)
        end

        blocked_tasks = tasks
          .select { |task| task.status == :blocked }
          .map { |task| TaskView.new(task_ref: task.ref, status: task.status, phase: nil) }

        repairable_items = []
        repairable_items << "stale_shot_lock" if shot_state.stale?
        active_runs.each do |run|
          repairable_items << "stale_run:#{run.task_ref}" unless run.status == :active
        end

        Result.new(
          scheduler_state: scheduler_state,
          shot_state: shot_state,
          active_runs: active_runs.freeze,
          queued_tasks: queued_tasks.freeze,
          blocked_tasks: blocked_tasks.freeze,
          repairable_items: repairable_items.freeze
        )
      end

      private

      def active_run_status(run, shot_state)
        return :missing_run unless run
        return :terminal_run if run.terminal?
        return :stale_workspace unless workspace_present?(run)
        return :stale_process unless shot_state.active? || @execution_process_probe.active_execute_until_idle?

        :active
      end

      def workspace_present?(run)
        File.directory?(workspace_root_for(run))
      end

      def workspace_root_for(run)
        File.join(@storage_dir, "workspaces", slugify(run.task_ref), run.workspace_kind.to_s)
      end

      def slugify(task_ref)
        task_ref.gsub(/[^A-Za-z0-9._-]+/, "-")
      end

      def inspect_shot_lock
        path = File.join(@storage_dir, "scheduler-shot.lock")
        return ShotState.new(pid: nil, status: :none) unless File.exist?(path)

        pid = Integer(File.read(path).strip, 10)
        ShotState.new(pid: pid, status: process_alive?(pid) ? :active : :stale)
      rescue ArgumentError
        ShotState.new(pid: nil, status: :stale)
      end

      def process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end
    end
  end
end
