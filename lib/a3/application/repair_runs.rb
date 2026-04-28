# frozen_string_literal: true

module A3
  module Application
    class RepairRuns
      RepairAction = Struct.new(:kind, :target_ref, :applied, keyword_init: true)
      Result = Struct.new(:dry_run, :actions, keyword_init: true)

      def initialize(task_repository:, run_repository:, storage_dir:, execution_process_probe: nil, agent_job_store: nil)
        @task_repository = task_repository
        @run_repository = run_repository
        @storage_dir = File.expand_path(storage_dir)
        @execution_process_probe = execution_process_probe || A3::Application::ExecutionProcessProbe.new(storage_dir: @storage_dir)
        @agent_job_store = agent_job_store
      end

      def call(apply:)
        actions = []
        runs_by_ref = @run_repository.all.each_with_object({}) { |run, memo| memo[run.ref] = run }
        corrupt_run_refs = corrupt_run_refs_by_ref
        shot_active = active_shot_lock?
        direct_run_active = @execution_process_probe.active_execute_until_idle?

        if stale_shot_lock?
          clear_shot_lock if apply
          actions << RepairAction.new(kind: :stale_shot_lock, target_ref: nil, applied: apply)
          shot_active = false
        end

        @task_repository.all.each do |task|
          next unless task.current_run_ref

          run = runs_by_ref[task.current_run_ref]
          next if run && !run.terminal? && workspace_present?(run) && (shot_active || direct_run_active)

          stale_claimed_agent_jobs = stale_claimed_agent_jobs_for(run, shot_active: shot_active, direct_run_active: direct_run_active)

          if apply
            stale_claimed_agent_jobs.each do |job|
              agent_job_store.mark_stale(job_id: job.job_id, reason: "runtime process stopped before agent job result was recorded")
            end
            @task_repository.save(
              task.complete_run(next_phase: nil, terminal_status: task.status)
            )
          end

          actions << RepairAction.new(
            kind: stale_task_kind_for(
              run,
              task: task,
              corrupt_run_refs: corrupt_run_refs,
              stale_claimed_agent_jobs: stale_claimed_agent_jobs,
              shot_active: shot_active,
              direct_run_active: direct_run_active
            ),
            target_ref: task.ref,
            applied: apply
          )
        end

        Result.new(dry_run: !apply, actions: actions.freeze)
      end

      private

      def corrupt_run_refs_by_ref
        return [] unless @run_repository.respond_to?(:corrupt_run_refs)

        @run_repository.corrupt_run_refs
      end

      def stale_shot_lock?
        path = shot_lock_path
        return false unless File.exist?(path)

        pid = Integer(File.read(path).strip, 10)
        !process_alive?(pid)
      rescue ArgumentError
        true
      end

      def active_shot_lock?
        path = shot_lock_path
        return false unless File.exist?(path)

        pid = Integer(File.read(path).strip, 10)
        process_alive?(pid)
      rescue ArgumentError
        false
      end

      def clear_shot_lock
        File.delete(shot_lock_path) if File.exist?(shot_lock_path)
      end

      def shot_lock_path
        File.join(@storage_dir, "scheduler-shot.lock")
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

      def stale_task_kind_for(run, task:, corrupt_run_refs:, stale_claimed_agent_jobs:, shot_active:, direct_run_active:)
        return :stale_task_claimed_agent_job unless stale_claimed_agent_jobs.empty?
        return :corrupt_run_record if corrupt_run_refs.include?(task.current_run_ref)
        return :stale_task_missing_run if run.nil?
        return :stale_task_terminal_run if run.terminal?
        return :stale_task_missing_workspace unless workspace_present?(run)
        return :stale_task_missing_process unless shot_active || direct_run_active

        :stale_task_missing_workspace
      end

      def stale_claimed_agent_jobs_for(run, shot_active:, direct_run_active:)
        return [] unless run
        return [] if run.terminal?
        return [] if shot_active || direct_run_active
        return [] unless workspace_present?(run)
        return [] unless File.exist?(agent_jobs_path)

        agent_job_store.all.select do |job|
          job.state == :claimed && job.request.run_ref == run.ref
        end
      rescue JSON::ParserError, A3::Domain::ConfigurationError
        []
      end

      def agent_job_store
        @agent_job_store ||= A3::Infra::JsonAgentJobStore.new(agent_jobs_path)
      end

      def agent_jobs_path
        File.join(@storage_dir, "agent_jobs.json")
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
