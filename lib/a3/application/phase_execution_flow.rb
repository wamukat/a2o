# frozen_string_literal: true

require "tmpdir"
require "a3/infra/workspace_trace_logger"

module A3
  module Application
    class PhaseExecutionFlow
      Result = Struct.new(:task, :run, :workspace, keyword_init: true)

      def initialize(task_repository:, run_repository:, register_completed_run:, prepare_workspace:, blocked_diagnosis_factory: A3::Domain::BlockedDiagnosisFactory.new)
        @task_repository = task_repository
        @run_repository = run_repository
        @register_completed_run = register_completed_run
        @blocked_diagnosis_factory = blocked_diagnosis_factory
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
        A3::Infra::WorkspaceTraceLogger.log(
          workspace_root: prepared_workspace.workspace.root_path,
          event: "phase_execution.execute.finish",
          payload: {
            "task_ref" => task.ref,
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "success" => execution.success,
            "summary" => execution.summary,
            "failing_command" => execution.failing_command,
            "observed_state" => execution.observed_state
          }
        )
        completion = @orchestrator.persist_and_complete(
          task_ref: task_ref,
          run_ref: run_ref,
          task: task,
          run: run,
          runtime: runtime,
          execution: execution,
          verification_summary: strategy.verification_summary(execution),
          blocked_diagnosis: execution.success? ? nil : @blocked_diagnosis_factory.call(
            task: task,
            run: run,
            execution: execution,
            expected_state: strategy.blocked_expected_state,
            default_failing_command: strategy.blocked_default_failing_command,
            extra_diagnostics: strategy.blocked_extra_diagnostics(execution)
          ),
          execution_record: execution_record || default_execution_record(execution: execution, runtime: runtime)
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

      def default_execution_record(execution:, runtime:)
        A3::Domain::PhaseExecutionRecord.from_execution_result(
          execution,
          runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.from_phase_runtime(runtime)
        )
      end
    end
  end
end
