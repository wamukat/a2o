# frozen_string_literal: true

module A3
  module Application
    class PrepareWorkspace
      Result = Struct.new(:workspace, keyword_init: true)

      def initialize(workspace_plan_builder: BuildWorkspacePlan.new, provisioner:)
        @workspace_plan_builder = workspace_plan_builder
        @provisioner = provisioner
      end

      def call(task:, phase:, source_descriptor:, scope_snapshot:, artifact_owner:, bootstrap_marker:)
        workspace_plan = @workspace_plan_builder.call(
          phase: phase.to_sym,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot
        )

        Result.new(
          workspace: @provisioner.call(
            task: task,
            workspace_plan: workspace_plan,
            artifact_owner: artifact_owner,
            bootstrap_marker: bootstrap_marker
          )
        )
      end
    end
  end
end
