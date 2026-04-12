# frozen_string_literal: true

require "tmpdir"

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
        bootstrap_marker
        task = @task_repository.fetch(task_ref)
        started = @start_phase.call(
          task: task,
          phase: phase,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot,
          review_target: review_target,
          artifact_owner: artifact_owner
        )
        registered = @register_started_run.call(task_ref: task_ref, run: started.run)
        Result.new(task: registered.task, run: registered.run, workspace: control_plane_workspace_for(registered.run))
      end

      private

      def control_plane_workspace_for(run)
        A3::Domain::PreparedWorkspace.new(
          workspace_kind: run.workspace_kind,
          root_path: File.join(Dir.tmpdir, "a3-control-plane-workspace", safe_id(run.ref)),
          source_descriptor: run.source_descriptor,
          slot_paths: {}
        )
      end

      def safe_id(value)
        value.to_s.gsub(/[^A-Za-z0-9._:-]/, "-")
      end
    end
  end
end
