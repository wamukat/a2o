# frozen_string_literal: true

module A3
  module CLI
    module CommandRouter
      class Definition < Struct.new(:handler, :session_kind, :needs_worker_gateway, keyword_init: true)
        def manifest?
          session_kind == :manifest
        end

        def storage?
          session_kind == :storage
        end

        def storage_runtime_package?
          session_kind == :storage_runtime_package
        end

        def runtime?
          session_kind == :runtime
        end

        def requires_container_dependencies?
          storage? || storage_runtime_package? || runtime?
        end
      end

      COMMANDS = {
        "start-run" => Definition.new(handler: :handle_start_run, session_kind: :storage),
        "complete-run" => Definition.new(handler: :handle_complete_run, session_kind: :storage),
        "plan-rerun" => Definition.new(handler: :handle_plan_rerun, session_kind: :storage),
        "recover-rerun" => Definition.new(handler: :handle_recover_rerun, session_kind: :storage_runtime_package),
        "reconcile-merge-recovery" => Definition.new(handler: :handle_reconcile_merge_recovery, session_kind: :storage),
        "diagnose-blocked" => Definition.new(handler: :handle_diagnose_blocked, session_kind: :storage),
        "show-blocked-diagnosis" => Definition.new(handler: :handle_show_blocked_diagnosis, session_kind: :storage_runtime_package),
        "plan-next-runnable-task" => Definition.new(handler: :handle_plan_next_runnable_task, session_kind: :storage),
        "plan-next-decomposition-task" => Definition.new(handler: :handle_plan_next_decomposition_task, session_kind: :storage),
        "run-decomposition-investigation" => Definition.new(handler: :handle_run_decomposition_investigation, session_kind: :runtime),
        "run-decomposition-proposal-author" => Definition.new(handler: :handle_run_decomposition_proposal_author, session_kind: :runtime),
        "run-decomposition-proposal-review" => Definition.new(handler: :handle_run_decomposition_proposal_review, session_kind: :runtime),
        "run-decomposition-child-creation" => Definition.new(handler: :handle_run_decomposition_child_creation, session_kind: :storage),
        "show-decomposition-status" => Definition.new(handler: :handle_show_decomposition_status, session_kind: :storage),
        "cleanup-decomposition-trial" => Definition.new(handler: :handle_cleanup_decomposition_trial, session_kind: :storage),
        "execute-next-runnable-task" => Definition.new(handler: :handle_execute_next_runnable_task, needs_worker_gateway: true, session_kind: :runtime),
        "execute-until-idle" => Definition.new(handler: :handle_execute_until_idle, needs_worker_gateway: true, session_kind: :runtime),
        "show-scheduler-state" => Definition.new(handler: :handle_show_scheduler_state, session_kind: :storage),
        "show-state" => Definition.new(handler: :handle_show_state, session_kind: :storage),
        "repair-runs" => Definition.new(handler: :handle_repair_runs, session_kind: :storage),
        "force-stop-task" => Definition.new(handler: :handle_force_stop_task, session_kind: :storage),
        "force-stop-run" => Definition.new(handler: :handle_force_stop_run, session_kind: :storage),
        "show-scheduler-history" => Definition.new(handler: :handle_show_scheduler_history, session_kind: :storage),
        "pause-scheduler" => Definition.new(handler: :handle_pause_scheduler, session_kind: :storage),
        "resume-scheduler" => Definition.new(handler: :handle_resume_scheduler, session_kind: :storage),
        "cleanup-terminal-workspaces" => Definition.new(handler: :handle_cleanup_terminal_workspaces, session_kind: :storage),
        "quarantine-terminal-workspaces" => Definition.new(handler: :handle_quarantine_terminal_workspaces, session_kind: :storage),
        "prepare-workspace" => Definition.new(handler: :handle_prepare_workspace, session_kind: :storage),
        "show-project-surface" => Definition.new(handler: :handle_show_project_surface, session_kind: :manifest),
        "show-project-context" => Definition.new(handler: :handle_show_project_context, session_kind: :manifest),
        "show-phase-runtime-config" => Definition.new(handler: :handle_show_phase_runtime_config, session_kind: :manifest),
        "show-runtime-package" => Definition.new(handler: :handle_show_runtime_package, session_kind: :runtime_package),
        "doctor-runtime" => Definition.new(handler: :handle_doctor_runtime, session_kind: :runtime_package),
        "migrate-scheduler-store" => Definition.new(handler: :handle_migrate_scheduler_store, session_kind: :runtime_package),
        "show-merge-plan" => Definition.new(handler: :handle_show_merge_plan, session_kind: :runtime),
        "show-task" => Definition.new(handler: :handle_show_task, session_kind: :storage),
        "show-run" => Definition.new(handler: :handle_show_run, session_kind: :storage_runtime_package),
        "skill-feedback-list" => Definition.new(handler: :handle_skill_feedback_list, session_kind: :storage),
        "skill-feedback-propose" => Definition.new(handler: :handle_skill_feedback_propose, session_kind: :storage),
        "metrics" => Definition.new(handler: :handle_metrics, session_kind: :storage),
        "watch-summary" => Definition.new(handler: :handle_watch_summary, session_kind: :storage),
        "host" => Definition.new(handler: :handle_host, session_kind: :host_distribution),
        "agent" => Definition.new(handler: :handle_agent, session_kind: :agent_distribution),
        "agent-server" => Definition.new(handler: :handle_agent_server, session_kind: :agent_control),
        "agent-artifact-read" => Definition.new(handler: :handle_agent_artifact_read, session_kind: :agent_control),
        "agent-artifact-cleanup" => Definition.new(handler: :handle_agent_artifact_cleanup, session_kind: :agent_control),
        "clear-runtime-logs" => Definition.new(handler: :handle_clear_runtime_logs, session_kind: :storage),
        "run-verification" => Definition.new(handler: :handle_run_verification, needs_worker_gateway: true, session_kind: :runtime),
        "run-worker-phase" => Definition.new(handler: :handle_run_worker_phase, needs_worker_gateway: true, session_kind: :runtime),
        "run-merge" => Definition.new(handler: :handle_run_merge, needs_worker_gateway: true, session_kind: :runtime),
        "root-utility" => Definition.new(handler: :handle_root_utility),
        "worker:stdin-bundle" => Definition.new(handler: :handle_worker_stdin_bundle)
      }.freeze

      module_function

      def dispatch(cli, command:, argv:, out:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
        definition = definition_for(command)
        return false unless definition

        kwargs = { out: out }
        if definition.requires_container_dependencies?
          kwargs[:run_id_generator] = run_id_generator
          kwargs[:command_runner] = command_runner
          kwargs[:merge_runner] = merge_runner
        end
        kwargs[:worker_gateway] = worker_gateway if definition.needs_worker_gateway
        cli.public_send(definition.handler, argv, **kwargs)
        true
      end

      def definition_for(command)
        COMMANDS[command]
      end

      def session_kind_for(command)
        definition = definition_for(command)
        definition&.session_kind
      end
    end
  end
end
