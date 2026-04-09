# frozen_string_literal: true

module A3
  module Application
    class StartRun
      Result = Struct.new(:task, :run, :workspace, keyword_init: true)

      def initialize(start_phase:, register_started_run:, task_repository:, prepare_workspace:)
        @start_phase = start_phase
        @register_started_run = register_started_run
        @task_repository = task_repository
        @prepare_workspace = prepare_workspace
      end

      def call(task_ref:, phase:, source_descriptor:, scope_snapshot:, review_target:, artifact_owner:, bootstrap_marker:)
        task = @task_repository.fetch(task_ref)
        prepared_workspace = @prepare_workspace.call(
          task: task,
          phase: phase,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          artifact_owner: artifact_owner,
          bootstrap_marker: bootstrap_marker
        )
        started = @start_phase.call(
          task: task,
          phase: phase,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          review_target: review_target,
          artifact_owner: artifact_owner
        )
        validate_workspace_source_descriptor!(prepared_workspace.workspace, started.run)

        registered = @register_started_run.call(task_ref: task_ref, run: started.run)
        Result.new(task: registered.task, run: registered.run, workspace: prepared_workspace.workspace)
      end

      private

      def validate_workspace_source_descriptor!(workspace, run)
        return if workspace.source_descriptor == run.source_descriptor

        raise A3::Domain::ConfigurationError,
          "prepared workspace source descriptor does not match started run source descriptor"
      end
    end
  end
end
