# frozen_string_literal: true

module A3
  module Infra
    class DisabledWorkspaceChangePublisher
      def publish(run:, workspace:, execution:, remediation_commands: [])
        workspace
        execution
        remediation_commands
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "workspace publication must be executed by a3-agent",
          failing_command: "workspace_change_publication",
          observed_state: "engine_workspace_mutation_disabled",
          diagnostics: {
            "task_ref" => run.task_ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s
          }
        )
      end
    end
  end
end
