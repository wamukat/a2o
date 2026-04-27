# frozen_string_literal: true

module A3
  module Infra
    class DisabledMergeRunner
      def run(merge_plan, workspace:)
        workspace
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "merge must be executed by a2o-agent; configure --merge-runner agent-http",
          failing_command: "merge_runner",
          observed_state: "engine_merge_mutation_disabled",
          diagnostics: {
            "task_ref" => merge_plan.task_ref,
            "merge_source_ref" => merge_plan.merge_source.source_ref,
            "target_ref" => merge_plan.integration_target.target_ref
          }
        )
      end

      def agent_owned?
        false
      end
    end
  end
end
