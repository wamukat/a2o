# frozen_string_literal: true

module A3
  module Application
    class WorkerPhaseExecutionStrategy
      def initialize(worker_gateway:, task_packet_builder:, workspace_change_publisher: A3::Infra::DisabledWorkspaceChangePublisher.new)
        @worker_gateway = worker_gateway
        @task_packet_builder = task_packet_builder
        @workspace_change_publisher = workspace_change_publisher
      end

      def execute(task:, run:, runtime:, workspace:)
        execution = @worker_gateway.run(
          skill: worker_skill_for(run.phase, runtime),
          workspace: workspace,
          task: task,
          run: run,
          phase_runtime: runtime,
          task_packet: @task_packet_builder.call(task: task)
        )
        execution = append_worker_response_bundle(execution)
        return execution unless execution.success?
        return execution unless run.phase.to_sym == :implementation
        return execution if agent_owned_publication?

        publication = @workspace_change_publisher.publish(
          run: run,
          workspace: workspace,
          execution: execution,
          # Publication runs in the A3 control-plane runtime and must stay
          # project-runtime free. Remediation belongs to verification, where
          # the configured command runner can target the host/dev-env agent.
          remediation_commands: []
        )
        return publication unless publication.success?

        published_slots = Array(publication.diagnostics.fetch("published_slots", []))
        return execution if published_slots.empty?

        A3::Application::ExecutionResult.new(
          success: execution.success?,
          summary: [execution.summary, publication.summary].reject(&:empty?).join("; "),
          failing_command: execution.failing_command,
          observed_state: execution.observed_state,
          diagnostics: execution.diagnostics.merge(publication.diagnostics),
          response_bundle: execution.response_bundle
        )
      end

      def blocked_expected_state
        "worker phase succeeds"
      end

      def requires_workspace?
        !agent_owned_workspace?
      end

      def blocked_default_failing_command
        "worker_gateway"
      end

      def blocked_extra_diagnostics(_execution)
        {}
      end

      def verification_summary(_execution)
        nil
      end

      private

      def agent_owned_workspace?
        @worker_gateway.respond_to?(:agent_owned_workspace?) && @worker_gateway.agent_owned_workspace?
      end

      def agent_owned_publication?
        @worker_gateway.respond_to?(:agent_owned_publication?) && @worker_gateway.agent_owned_publication?
      end

      def append_worker_response_bundle(execution)
        return execution unless execution.response_bundle

        infra_diagnostics = execution.diagnostics.merge("worker_response_bundle" => execution.response_bundle)
        A3::Application::ExecutionResult.new(
          success: execution.success?,
          summary: execution.summary,
          failing_command: execution.failing_command,
          observed_state: execution.observed_state,
          diagnostics: infra_diagnostics,
          response_bundle: execution.response_bundle
        )
      end

      def worker_skill_for(phase, runtime)
        case phase.to_sym
        when :implementation
          runtime.implementation_skill
        when :review
          runtime.review_skill
        else
          raise A3::Domain::InvalidPhaseError, "worker phase unsupported for #{phase}"
        end
      end
    end

    class VerificationExecutionStrategy
      def initialize(command_runner:)
        @command_runner = command_runner
      end

      def execute(task:, run:, runtime:, workspace:)
        remediation = run_remediation(task: task, run: run, runtime: runtime, workspace: workspace)
        return remediation unless remediation.success?

        verification = run_verification_commands(task: task, run: run, runtime: runtime, workspace: workspace)
        return verification unless verification.success?
        return verification if runtime.remediation_commands.empty?

        A3::Application::ExecutionResult.new(
          success: true,
          summary: [remediation.summary, verification.summary].reject(&:empty?).join("; "),
          diagnostics: verification.diagnostics
        )
      end

      def run_remediation(task:, run:, runtime:, workspace:)
        return A3::Application::ExecutionResult.new(success: true, summary: "") if runtime.remediation_commands.empty?

        summaries = []
        resolve_remediation_workspaces(run: run, workspace: workspace).each do |target_workspace|
          result = @command_runner.run(runtime.remediation_commands, workspace: target_workspace, task: task, run: run, command_intent: :remediation)
          return result unless result.success?

          summaries << result.summary
        end

        A3::Application::ExecutionResult.new(
          success: true,
          summary: summaries.reject(&:empty?).join("; ")
        )
      end

      def resolve_remediation_workspaces(run:, workspace:)
        return [workspace] if @command_runner.respond_to?(:agent_owned_workspace?) && @command_runner.agent_owned_workspace?
        return [workspace] if workspace.slot_paths.empty?

        target_slots = run.scope_snapshot.verification_scope.map do |slot_name|
          slot_path = workspace.slot_paths[slot_name]
          next if slot_path.nil?

          workspace.scoped_to(slot_path)
        end.compact
        return [workspace] if target_slots.empty?

        target_slots
      end

      def run_verification_commands(task:, run:, runtime:, workspace:)
        @command_runner.run(runtime.verification_commands, workspace: workspace, task: task, run: run)
      end

      def blocked_expected_state
        "verification commands pass"
      end

      def requires_workspace?
        !(@command_runner.respond_to?(:agent_owned_workspace?) && @command_runner.agent_owned_workspace?)
      end

      def blocked_default_failing_command
        "verification"
      end

      def blocked_extra_diagnostics(execution)
        execution.diagnostics
      end

      def verification_summary(execution)
        execution.success? ? execution.summary : nil
      end

      private
    end

    class MergeExecutionStrategy
      def initialize(merge_runner:, merge_plan:)
        @merge_runner = merge_runner
        @merge_plan = merge_plan
      end

      def execute(task:, run:, runtime:, workspace:)
        task
        run
        runtime
        @merge_runner.run(@merge_plan, workspace: workspace)
      end

      def requires_workspace?
        !(@merge_runner.respond_to?(:agent_owned?) && @merge_runner.agent_owned?)
      end

      def blocked_expected_state
        "merge succeeds"
      end

      def blocked_default_failing_command
        "merge"
      end

      def blocked_extra_diagnostics(execution)
        execution.diagnostics
      end

      def verification_summary(execution)
        execution.success? ? execution.summary : nil
      end
    end
  end
end
