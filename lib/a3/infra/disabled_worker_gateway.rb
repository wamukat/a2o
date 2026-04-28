# frozen_string_literal: true

module A3
  module Infra
    class DisabledWorkerGateway
      def run(skill:, workspace:, task:, run:, phase_runtime:, task_packet:, prior_review_feedback: nil)
        skill
        workspace
        phase_runtime
        task_packet
        prior_review_feedback
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "worker phase must be executed by a2o-agent; configure --worker-gateway agent-http",
          failing_command: "worker_gateway",
          observed_state: "engine_worker_execution_disabled",
          diagnostics: {
            "task_ref" => task.ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s
          }
        )
      end

      def agent_owned_workspace?
        false
      end

      def agent_owned_publication?
        false
      end
    end
  end
end
