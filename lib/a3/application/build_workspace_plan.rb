# frozen_string_literal: true

module A3
  module Application
    class BuildWorkspacePlan
      def initialize(workspace_policy: A3::Domain::WorkspacePolicy.new)
        @workspace_policy = workspace_policy
      end

      def call(phase:, source_descriptor:, scope_snapshot:)
        @workspace_policy.build_plan(
          phase: phase,
          source_descriptor: source_descriptor,
          scope_snapshot: scope_snapshot
        )
      end
    end
  end
end
