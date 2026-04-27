# frozen_string_literal: true

require "tmpdir"
require_relative "run_notification_hooks"
require "a3/infra/workspace_trace_logger"

module A3
  module Application
    class PhaseExecutionFlow
      Result = Struct.new(:task, :run, :workspace, keyword_init: true)

      def initialize(task_repository:, run_repository:, register_completed_run:, prepare_workspace:, inherited_parent_state_resolver: nil, blocked_diagnosis_factory: A3::Domain::BlockedDiagnosisFactory.new, notification_hook_runner: A3::Application::RunNotificationHooks.new)
        @task_repository = task_repository
        @run_repository = run_repository
        @register_completed_run = register_completed_run
        @inherited_parent_state_resolver = inherited_parent_state_resolver
        @blocked_diagnosis_factory = blocked_diagnosis_factory
        @notification_hook_runner = notification_hook_runner
        @orchestrator = A3::Application::PhaseExecutionOrchestrator.new(
          run_repository: run_repository,
          register_completed_run: register_completed_run,
          prepare_workspace: prepare_workspace
        )
      end

      def call(task_ref:, run_ref:, project_context:, strategy:, execution_record: nil, task: nil, run: nil)
        task ||= @task_repository.fetch(task_ref)
        run ||= @run_repository.fetch(run_ref)
        runtime = project_context.resolve_phase_runtime(task: task, phase: run.phase)
        prepared_workspace = prepare_for_strategy(strategy: strategy, task: task, run: run, runtime: runtime)
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: prepared_workspace.workspace.root_path,
          event: "phase_execution.execute.start",
          payload: {
            "task_ref" => task.ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "workspace_kind" => prepared_workspace.workspace.workspace_kind.to_s
          }
        )
        execution = strategy.execute(
          task: task,
          run: run,
          runtime: runtime,
          workspace: prepared_workspace.workspace
        )
        execution_with_context = merge_inherited_parent_diagnostics(task: task, run: run, execution: execution)
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: prepared_workspace.workspace.root_path,
          event: "phase_execution.execute.finish",
          payload: {
            "task_ref" => task.ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "success" => execution_with_context.success,
            "summary" => execution_with_context.summary,
            "failing_command" => execution_with_context.failing_command,
            "observed_state" => execution_with_context.observed_state
          }
        )
        completion = @orchestrator.persist_and_complete(
          task_ref: task_ref,
          run_ref: run_ref,
          task: task,
          run: run,
          runtime: runtime,
          execution: execution_with_context,
          verification_summary: strategy.verification_summary(execution_with_context),
          blocked_diagnosis: execution_with_context.success? ? nil : @blocked_diagnosis_factory.call(
            task: task,
            run: run,
            execution: execution_with_context,
            expected_state: strategy.blocked_expected_state,
            default_failing_command: strategy.blocked_default_failing_command,
            extra_diagnostics: strategy.blocked_extra_diagnostics(execution_with_context)
          ),
          execution_record: execution_record || default_execution_record(task: task, run: run, execution: execution_with_context, runtime: runtime)
        )
        completion = run_notification_hooks(
          completion: completion,
          runtime: runtime,
          workspace: prepared_workspace.workspace
        )
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: prepared_workspace.workspace.root_path,
          event: "phase_execution.persist.finish",
          payload: {
            "task_ref" => completion.task.ref,
            "run_ref" => completion.run.ref,
            "phase" => completion.run.phase.to_s,
            "task_status" => completion.task.status.to_s,
            "run_terminal_outcome" => completion.run.terminal_outcome&.to_s
          }
        )
        Result.new(task: completion.task, run: completion.run, workspace: prepared_workspace.workspace)
      end

      private

      def prepare_for_strategy(strategy:, task:, run:, runtime:)
        return @orchestrator.prepare(task: task, run: run, runtime: runtime) if notification_hooks_required?(runtime)
        return @orchestrator.prepare(task: task, run: run, runtime: runtime) unless strategy.respond_to?(:requires_workspace?) && !strategy.requires_workspace?

        Struct.new(:workspace).new(
          A3::Domain::PreparedWorkspace.new(
            workspace_kind: run.workspace_kind,
            root_path: File.join(Dir.tmpdir, "a3-control-plane-workspace", safe_trace_id(run.ref)),
            source_descriptor: run.source_descriptor,
            slot_paths: {}
          )
        )
      end

      def safe_trace_id(value)
        value.to_s.gsub(/[^A-Za-z0-9._:-]/, "-")
      end

      def default_execution_record(task:, run:, execution:, runtime:)
        A3::Domain::PhaseExecutionRecord.from_execution_result(
          execution,
          runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.from_phase_runtime(runtime)
        )
      end

      def merge_inherited_parent_diagnostics(task:, run:, execution:)
        diagnostics = execution.diagnostics.dup
        inherited_parent_snapshot = @inherited_parent_state_resolver&.snapshot_for(task: task, phase: run.phase)
        diagnostics.merge!(inherited_parent_snapshot.to_h) if inherited_parent_snapshot
        execution.with_diagnostics(diagnostics)
      end

      def run_notification_hooks(completion:, runtime:, workspace:)
        events = notification_events_for(task: completion.task, run: completion.run)
        result = @notification_hook_runner.call(
          events: events,
          task: completion.task,
          run: completion.run,
          runtime: runtime,
          workspace: workspace
        )
        return completion if result.hook_results.empty?

        @run_repository.save(result.run)
        if runtime.notification_config.blocking? && result.failed?
          raise A3::Domain::ConfigurationError, "notification hook failed and runtime.notifications.failure_policy=blocking"
        end

        Result.new(task: completion.task, run: result.run, workspace: workspace)
      end

      def notification_events_for(task:, run:)
        events = ["task.phase_completed"]
        events << "task.blocked" if task.status == :blocked
        events << "task.completed" if task.status == :done
        events << "task.reworked" if run.terminal_outcome == :rework
        events << "parent.follow_up_child_created" if run.terminal_outcome == :follow_up_child
        events
      end

      def notification_hooks_required?(runtime)
        emitted_events = %w[
          task.phase_completed
          task.blocked
          task.completed
          task.reworked
          parent.follow_up_child_created
        ]
        emitted_events.any? { |event| runtime.notification_config.hooks_for(event).any? }
      end
    end
  end
end
