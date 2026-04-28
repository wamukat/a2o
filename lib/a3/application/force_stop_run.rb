# frozen_string_literal: true

require "fileutils"
require "json"

module A3
  module Application
    class ForceStopRun
      StoppedJob = Struct.new(:job_id, :state, keyword_init: true)
      Result = Struct.new(:task, :run, :stopped_jobs, :cleaned_paths, :already_terminal, keyword_init: true)

      def initialize(task_repository:, run_repository:, storage_dir:, agent_job_store: nil, provisioner: nil)
        @task_repository = task_repository
        @run_repository = run_repository
        @storage_dir = File.expand_path(storage_dir)
        @agent_job_store = agent_job_store
        @provisioner = provisioner
      end

      def call_task(task_ref:, outcome: :cancelled)
        task = @task_repository.fetch(task_ref)
        raise A3::Domain::ConfigurationError, "task #{task.ref} has no active current_run_ref" unless task.current_run_ref

        stop(task: task, run: @run_repository.fetch(task.current_run_ref), outcome: outcome)
      end

      def call_run(run_ref:, outcome: :cancelled)
        run = @run_repository.fetch(run_ref)
        task = @task_repository.fetch(run.task_ref)
        stop(task: task, run: run, outcome: outcome)
      end

      private

      def stop(task:, run:, outcome:)
        unless task.ref == run.task_ref
          raise A3::Domain::ConfigurationError, "run #{run.ref} belongs to #{run.task_ref}, not #{task.ref}"
        end

        stopped_jobs = mark_agent_jobs_stale(run)
        cleaned_paths = cleanup_workspace(task: task, run: run)

        if run.terminal?
          return Result.new(
            task: task,
            run: run,
            stopped_jobs: stopped_jobs.freeze,
            cleaned_paths: cleaned_paths.freeze,
            already_terminal: true
          )
        end

        completed_run = run.complete(outcome: outcome)
        completed_task =
          if task.current_run_ref == run.ref
            task.complete_run(next_phase: nil, terminal_status: task.status)
          else
            task
          end

        @run_repository.save(completed_run)
        @task_repository.save(completed_task)

        Result.new(
          task: completed_task,
          run: completed_run,
          stopped_jobs: stopped_jobs.freeze,
          cleaned_paths: cleaned_paths.freeze,
          already_terminal: false
        )
      end

      def mark_agent_jobs_stale(run)
        return [] unless File.exist?(agent_jobs_path)

        agent_job_store.all
          .select { |job| job.request.run_ref == run.ref && !job.terminal? }
          .map do |job|
            stale = agent_job_store.mark_stale(
              job_id: job.job_id,
              reason: "force-stopped runtime run #{run.ref}"
            )
            StoppedJob.new(job_id: stale.job_id, state: stale.state)
          end
      rescue JSON::ParserError, A3::Domain::ConfigurationError
        []
      end

      def cleanup_workspace(task:, run:)
        if @provisioner
          return @provisioner.cleanup_task(
            task_ref: task.ref,
            scopes: [run.workspace_kind],
            dry_run: false,
            **cleanup_workspace_options_for(task)
          )
        end

        root = workspace_root_for(task: task, run: run)
        return [] unless File.directory?(root)

        FileUtils.rm_rf(root)
        [root]
      end

      def cleanup_workspace_options_for(task)
        if task.parent_ref
          {
            parent_ref: task.parent_ref,
            parent_workspace_ref: parent_workspace_ref_for(task.parent_ref)
          }
        elsif task.kind.to_sym == :parent
          { workspace_ref: parent_workspace_ref_for(task.ref) }
        else
          {}
        end
      end

      def workspace_root_for(task:, run:)
        if task.parent_ref
          return File.join(@storage_dir, "workspaces", slugify(parent_workspace_ref_for(task.parent_ref)), "children", slugify(task.ref), run.workspace_kind.to_s)
        end

        workspace_ref = task.kind.to_sym == :parent ? parent_workspace_ref_for(task.ref) : task.ref
        File.join(@storage_dir, "workspaces", slugify(workspace_ref), run.workspace_kind.to_s)
      end

      def parent_workspace_ref_for(parent_ref)
        "#{parent_ref}-parent"
      end

      def slugify(task_ref)
        task_ref.gsub(/[^A-Za-z0-9._-]+/, "-")
      end

      def agent_job_store
        @agent_job_store ||= A3::Infra::JsonAgentJobStore.new(agent_jobs_path)
      end

      def agent_jobs_path
        File.join(@storage_dir, "agent_jobs.json")
      end
    end
  end
end
