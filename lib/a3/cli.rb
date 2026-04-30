# frozen_string_literal: true

require "optparse"
require "pathname"
require "shellwords"
require "json"
require "csv"
require "time"
require "a3/domain/phase_source_policy"
require "a3/cli/command_router"
require "a3/cli/handler_support"
require "a3/cli/show_output_formatter"
require "a3/cli/runtime_output_formatter"

module A3
  module CLI
    extend HandlerSupport
    module_function

    def start(argv, out: $stdout, run_id_generator: -> { SecureRandom.uuid }, command_runner: A3::Infra::LocalCommandRunner.new, merge_runner: A3::Infra::DisabledMergeRunner.new, worker_gateway: nil)
      command = argv.shift
      if command.nil? || %w[help -h --help].include?(command)
        print_public_usage(out)
        return
      end
      dispatched = CommandRouter.dispatch(
        self,
        command: command,
        argv: argv,
        out: out,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner,
        worker_gateway: worker_gateway
      )
      unless dispatched
        out.puts("unknown command: #{command}")
        print_public_usage(out)
      end
    end

    def print_public_usage(out)
      out.puts("A2O runtime container CLI")
      out.puts("")
      out.puts("This help is for the runtime container entrypoint. Install and use the host launcher for setup commands such as `a2o project template`.")
      out.puts("")
      out.puts("usage:")
      out.puts("  a2o host install --output-dir DIR --share-dir DIR [--runtime-image IMAGE]")
      out.puts("  a2o agent package list|verify|export")
      out.puts("  a2o execute-until-idle [options] project.yaml")
      out.puts("  a2o worker:stdin-bundle")
      out.puts("")
      out.puts("host launcher:")
      out.puts("  docker run --rm -v \"$PWD/.work/a2o:/out\" ghcr.io/wamukat/a2o-engine:0.5.54 a2o host install --output-dir /out/bin --share-dir /out/share")
      out.puts("  .work/a2o/bin/a2o project template --help")
    end

    def handle_start_run(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_start_run_options(argv)
      container = build_storage_container(
        options: options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      )
      task = container.fetch(:task_repository).fetch(options.fetch(:task_ref))

      result = container.fetch(:start_run).call(
        task_ref: task.ref,
        phase: options.fetch(:phase),
        source_descriptor: source_descriptor_for(task: task, options: options),
        scope_snapshot: container.fetch(:build_scope_snapshot).call(task: task),
        review_target: review_target_for(task: task, options: options),
        artifact_owner: container.fetch(:build_artifact_owner).call(
          task: task,
          snapshot_version: options.fetch(:review_head)
        ),
        bootstrap_marker: options.fetch(:bootstrap_marker)
      )

      out.puts("started run #{result.run.ref} for #{result.task.ref} at phase #{result.run.phase}")
    end

    def handle_complete_run(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_complete_run_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        result = container.fetch(:register_completed_run).call(
          task_ref: options.fetch(:task_ref),
          run_ref: options.fetch(:run_ref),
          outcome: options.fetch(:outcome)
        )

        out.puts("completed run #{result.run.ref} for #{result.task.ref} with outcome #{result.run.terminal_outcome}")
      end
    end

    def handle_plan_rerun(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_plan_rerun_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        result = container.fetch(:plan_persisted_rerun).call(
          task_ref: options.fetch(:task_ref),
          run_ref: options.fetch(:run_ref),
          current_source_type: options.fetch(:source_type).to_sym,
          current_source_ref: options.fetch(:source_ref),
          current_review_base: options.fetch(:review_base),
          current_review_head: options.fetch(:review_head),
          snapshot_version: options[:snapshot_version]
        )

        operator_action_required = result.decision.to_sym == :requires_operator_action
        out.puts("rerun decision #{result.decision} for #{result.run.ref} on #{result.task.ref}")
        out.puts("operator_action_required=#{operator_action_required}")
        if operator_action_required
          out.puts("rerun_hint=diagnose blocked state and choose a fresh rerun source")
        end
      end
    end

    def handle_recover_rerun(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_runtime_package_session(
        argv: argv,
        parse_with: :parse_recover_rerun_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        result = session.container.fetch(:recover_persisted_rerun).call(
          task_ref: session.options.fetch(:task_ref),
          run_ref: session.options.fetch(:run_ref),
          runtime_package: session.runtime_package,
          current_source_type: session.options.fetch(:source_type).to_sym,
          current_source_ref: session.options.fetch(:source_ref),
          current_review_base: session.options.fetch(:review_base),
          current_review_head: session.options.fetch(:review_head),
          snapshot_version: session.options.fetch(:snapshot_version)
        )

        out.puts("rerun recovery #{result.decision} for #{result.run.ref} on #{result.task.ref}")
        out.puts("action=#{result.recovery_action}")
        out.puts("target_phase=#{result.target_phase}")
        out.puts("runtime_package_guidance=#{result.recovery.runtime_package_guidance}") if result.recovery.runtime_package_guidance
        out.puts("runtime_package_contract_health=#{result.recovery.runtime_package_contract_health}") if result.recovery.runtime_package_contract_health
        out.puts("runtime_package_execution_modes=#{result.recovery.runtime_package_execution_modes}") if result.recovery.runtime_package_execution_modes
        out.puts("runtime_package_execution_mode_contract=#{result.recovery.runtime_package_execution_mode_contract}") if result.recovery.runtime_package_execution_mode_contract
        out.puts("runtime_package_schema_action=#{result.recovery.runtime_package_schema_action}") if result.recovery.runtime_package_schema_action
        out.puts("runtime_package_preset_schema_action=#{result.recovery.runtime_package_preset_schema_action}") if result.recovery.runtime_package_preset_schema_action
        out.puts("runtime_package_repo_source_action=#{result.recovery.runtime_package_repo_source_action}") if result.recovery.runtime_package_repo_source_action
        out.puts("runtime_package_secret_delivery_action=#{result.recovery.runtime_package_secret_delivery_action}") if result.recovery.runtime_package_secret_delivery_action
        out.puts("runtime_package_scheduler_store_migration_action=#{result.recovery.runtime_package_scheduler_store_migration_action}") if result.recovery.runtime_package_scheduler_store_migration_action
        out.puts("runtime_package_recommended_execution_mode=#{result.recovery.runtime_package_recommended_execution_mode}") if result.recovery.runtime_package_recommended_execution_mode
        out.puts("runtime_package_recommended_execution_mode_reason=#{result.recovery.runtime_package_recommended_execution_mode_reason}") if result.recovery.runtime_package_recommended_execution_mode_reason
        out.puts("runtime_package_recommended_execution_mode_command=#{result.recovery.runtime_package_recommended_execution_mode_command}")
        out.puts("runtime_package_operator_action=#{result.recovery.runtime_package_operator_action}")
        out.puts("runtime_package_operator_action_command=#{result.recovery.runtime_package_operator_action_command}")
        out.puts("runtime_package_next_execution_mode=#{result.recovery.runtime_package_next_execution_mode}")
        out.puts("runtime_package_next_execution_mode_reason=#{result.recovery.runtime_package_next_execution_mode_reason}")
        out.puts("runtime_package_next_execution_mode_command=#{result.recovery.runtime_package_next_execution_mode_command}")
        out.puts("runtime_package_next_command=#{result.recovery.runtime_package_next_command}") if result.recovery.runtime_package_next_command
        out.puts("runtime_package_doctor_command=#{result.recovery.runtime_package_doctor_command}") if result.recovery.runtime_package_doctor_command
        out.puts("runtime_package_migration_command=#{result.recovery.runtime_package_migration_command}") if result.recovery.runtime_package_migration_command
        out.puts("runtime_package_runtime_command=#{result.recovery.runtime_package_runtime_command}") if result.recovery.runtime_package_runtime_command
        out.puts("runtime_package_runtime_validation_command=#{result.recovery.runtime_package_runtime_validation_command}") if result.recovery.runtime_package_runtime_validation_command
        out.puts("runtime_package_startup_sequence=#{result.recovery.runtime_package_startup_sequence}") if result.recovery.runtime_package_startup_sequence
        out.puts("runtime_package_startup_blockers=#{result.recovery.runtime_package_startup_blockers}") if result.recovery.runtime_package_startup_blockers
        out.puts("runtime_package_persistent_state_model=#{result.recovery.runtime_package_persistent_state_model}") if result.recovery.runtime_package_persistent_state_model
        out.puts("runtime_package_retention_policy=#{result.recovery.runtime_package_retention_policy}") if result.recovery.runtime_package_retention_policy
        out.puts("runtime_package_materialization_model=#{result.recovery.runtime_package_materialization_model}") if result.recovery.runtime_package_materialization_model
        out.puts("runtime_package_runtime_configuration_model=#{result.recovery.runtime_package_runtime_configuration_model}") if result.recovery.runtime_package_runtime_configuration_model
        out.puts("runtime_package_repository_metadata_model=#{result.recovery.runtime_package_repository_metadata_model}") if result.recovery.runtime_package_repository_metadata_model
        out.puts("runtime_package_branch_resolution_model=#{result.recovery.runtime_package_branch_resolution_model}") if result.recovery.runtime_package_branch_resolution_model
        out.puts("runtime_package_credential_boundary_model=#{result.recovery.runtime_package_credential_boundary_model}") if result.recovery.runtime_package_credential_boundary_model
        out.puts("runtime_package_observability_boundary_model=#{result.recovery.runtime_package_observability_boundary_model}") if result.recovery.runtime_package_observability_boundary_model
        out.puts("runtime_package_deployment_shape=#{result.recovery.runtime_package_deployment_shape}") if result.recovery.runtime_package_deployment_shape
        out.puts("runtime_package_networking_boundary=#{result.recovery.runtime_package_networking_boundary}") if result.recovery.runtime_package_networking_boundary
        out.puts("runtime_package_upgrade_contract=#{result.recovery.runtime_package_upgrade_contract}") if result.recovery.runtime_package_upgrade_contract
        out.puts("runtime_package_fail_fast_policy=#{result.recovery.runtime_package_fail_fast_policy}") if result.recovery.runtime_package_fail_fast_policy
      end
    end

    def handle_reconcile_merge_recovery(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_reconcile_merge_recovery_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        result = container.fetch(:reconcile_manual_merge_recovery).call(
          task_ref: options.fetch(:task_ref),
          run_ref: options.fetch(:run_ref),
          target_ref: options.fetch(:target_ref),
          source_ref: options[:source_ref],
          publish_before_head: options[:publish_before_head],
          publish_after_head: options[:publish_after_head],
          summary: options[:summary]
        )

        out.puts("merge recovery reconciled for #{result.run.ref} on #{result.task.ref}")
        out.puts("status=#{result.task.status}")
        out.puts("verification_source_ref=#{result.task.verification_source_ref}")
        out.puts("merge_recovery_status=#{result.recovery.fetch('status')}")
      end
    end

    def handle_diagnose_blocked(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_diagnose_blocked_options(argv)
      container = build_storage_container(
        options: options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      )
      result = container.fetch(:diagnose_blocked_run).call(
        task_ref: options.fetch(:task_ref),
        run_ref: options.fetch(:run_ref),
        expected_state: options.fetch(:expected_state),
        observed_state: options.fetch(:observed_state),
        failing_command: options.fetch(:failing_command),
        diagnostic_summary: options.fetch(:diagnostic_summary),
        infra_diagnostics: options.fetch(:infra_diagnostics)
      )

      out.puts("blocked diagnosis #{result.diagnosis.outcome} for #{result.run.ref} on #{result.task.ref}: #{result.diagnosis.observed_state}")
    end

    def handle_show_blocked_diagnosis(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_runtime_package_session(
        argv: argv,
        parse_with: :parse_show_blocked_diagnosis_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        result = session.container.fetch(:show_blocked_diagnosis).call(
          task_ref: session.options.fetch(:task_ref),
          run_ref: session.options.fetch(:run_ref),
          runtime_package: session.runtime_package
        )

        ShowOutputFormatter.blocked_diagnosis_lines(result).each { |line| out.puts(line) }
      end
    end

    def handle_plan_next_runnable_task(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_storage_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        result = container.fetch(:plan_next_runnable_task).call

        if result.task
          out.puts("next runnable #{result.task.ref} at #{result.phase}")
          out.puts("selected_reason=#{result.selected_assessment.reason}") if result.selected_assessment
        else
          out.puts("no runnable task")
        end

        result.assessments.each do |assessment|
          next if assessment.runnable?

          line = "assessment #{assessment.task_ref} reason=#{assessment.reason}"
          unless assessment.blocking_task_refs.empty?
            line = "#{line} blocked_by=#{assessment.blocking_task_refs.join(',')}"
          end
          out.puts(line)
        end
      end
    end

    def handle_plan_next_decomposition_task(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_storage_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        result = container.fetch(:plan_next_decomposition_task).call

        if result.active_task
          out.puts("active decomposition #{result.active_task.ref}")
        elsif result.task
          out.puts("next decomposition #{result.task.ref}")
        else
          out.puts("no decomposition task")
        end

        result.candidates.each do |candidate|
          out.puts("candidate #{candidate.ref} status=#{candidate.status}")
        end
      end
    end

    def handle_run_decomposition_investigation(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_run_decomposition_investigation_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        task = resolve_direct_task(container: session.container, task_ref: session.options.fetch(:task_ref))
        bridge = build_external_task_bridge(session.options)
        result = A3::Application::RunDecompositionInvestigation.new(
          storage_dir: session.options.fetch(:storage_dir),
          project_root: File.dirname(session.options.fetch(:manifest_path)),
          progress_io: out,
          publish_external_task_activity: session.container.fetch(:external_task_activity_publisher)
        ).call(
          task: task,
          project_surface: session.project_surface,
          slot_paths: session.options.fetch(:repo_sources),
          task_snapshot: decomposition_task_snapshot(bridge: bridge, task: task),
          previous_evidence_path: default_decomposition_investigation_evidence_path(
            storage_dir: session.options.fetch(:storage_dir),
            task_ref: task.ref
          )
        )

        out.puts("decomposition investigation #{task.ref} success=#{result.success}")
        out.puts("summary=#{result.summary}")
        out.puts("evidence_path=#{result.evidence_path}")
      end
    end

    def handle_run_decomposition_proposal_author(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_run_decomposition_proposal_author_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        task = resolve_direct_task(container: session.container, task_ref: session.options.fetch(:task_ref))
        runner = A3::Application::RunDecompositionProposalAuthor.new(
          storage_dir: session.options.fetch(:storage_dir),
          project_root: File.dirname(session.options.fetch(:manifest_path)),
          publish_external_task_activity: session.container.fetch(:external_task_activity_publisher)
        )
        result = runner.call(
          task: task,
          project_surface: session.project_surface,
          investigation_evidence_path: session.options.fetch(:investigation_evidence_path)
        )

        out.puts("decomposition proposal #{task.ref} success=#{result.success}")
        out.puts("summary=#{result.summary}")
        out.puts("proposal_fingerprint=#{result.proposal_fingerprint}") if result.proposal_fingerprint
        out.puts("evidence_path=#{result.evidence_path}")
        out.puts("source_ticket_summary_published=#{result.source_ticket_summary_published}")
      end
    end

    def handle_run_decomposition_proposal_review(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_run_decomposition_proposal_review_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        task = resolve_direct_task(container: session.container, task_ref: session.options.fetch(:task_ref))
        result = A3::Application::RunDecompositionProposalReview.new(
          storage_dir: session.options.fetch(:storage_dir),
          project_root: File.dirname(session.options.fetch(:manifest_path)),
          publish_external_task_activity: session.container.fetch(:external_task_activity_publisher)
        ).call(
          task: task,
          project_surface: session.project_surface,
          proposal_evidence_path: session.options.fetch(:proposal_evidence_path)
        )

        out.puts("decomposition proposal review #{task.ref} disposition=#{result.disposition} success=#{result.success}")
        out.puts("summary=#{result.summary}")
        out.puts("critical_findings=#{result.critical_findings.size}")
        out.puts("evidence_path=#{result.evidence_path}")

        draft_result = run_automatic_decomposition_draft_child_creation(
          session: session,
          task: task,
          review_result: result
        )
        write_automatic_decomposition_draft_child_creation_result(out, task: task, result: draft_result)
      end
    end

    def handle_run_decomposition_child_creation(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_run_decomposition_child_creation_options(argv)
      repositories = build_watch_summary_repositories(options: options)
      external_task_source =
        if kanban_bridge_enabled?(options)
          build_external_task_source(options)
        else
          A3::Infra::NullExternalTaskSource.new
        end
      task = resolve_direct_task(
        task_repository: repositories.fetch(:task_repository),
        external_task_source: external_task_source,
        task_ref: options.fetch(:task_ref)
      )
      writer =
        if options.fetch(:gate)
          A3::Infra::KanbanCliProposalChildWriter.new(
            command_argv: kanban_command_argv(options),
            project: options.fetch(:kanban_project),
            working_dir: options[:kanban_working_dir]
          )
        else
          Object.new
        end
      result = A3::Application::RunDecompositionChildCreation.new(
        storage_dir: options.fetch(:storage_dir),
        child_writer: writer,
        publish_external_task_activity: build_decomposition_source_activity_publisher(options)
      ).call(
        task: task,
        gate: options.fetch(:gate),
        proposal_evidence_path: options[:proposal_evidence_path],
        review_evidence_path: options[:review_evidence_path]
      )

      if result.success.nil? && result.status == "gate_closed"
        out.puts("decomposition child creation #{task.ref} status=#{result.status}")
        out.puts("child_creation_result=not_attempted")
      else
        out.puts("decomposition child creation #{task.ref} success=#{result.success}")
        out.puts("status=#{result.status}") if result.status
      end
      out.puts("summary=#{result.summary}")
      out.puts("child_refs=#{result.child_refs.join(',')}")
      out.puts("child_keys=#{result.child_keys.join(',')}")
      out.puts("evidence_path=#{result.evidence_path}")
    end

    def handle_accept_decomposition_drafts(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_accept_decomposition_drafts_options(argv)
      repositories = build_watch_summary_repositories(options: options)
      external_task_source =
        if kanban_bridge_enabled?(options)
          build_external_task_source(options)
        else
          A3::Infra::NullExternalTaskSource.new
        end
      task = resolve_direct_task(
        task_repository: repositories.fetch(:task_repository),
        external_task_source: external_task_source,
        task_ref: options.fetch(:task_ref)
      )
      writer = A3::Infra::KanbanCliDraftAcceptanceWriter.new(
        command_argv: kanban_command_argv(options),
        project: options.fetch(:kanban_project),
        working_dir: options[:kanban_working_dir]
      )
      result = writer.call(
        parent_task_ref: task.ref,
        parent_external_task_id: task.external_task_id,
        child_refs: options.fetch(:child_refs),
        all: options.fetch(:all),
        ready_only: options.fetch(:ready_only),
        remove_draft_label: options.fetch(:remove_draft_label),
        parent_auto: options.fetch(:parent_auto)
      )

      out.puts("decomposition draft acceptance #{task.ref} success=#{result.success?}")
      out.puts("summary=#{result.summary}")
      out.puts("accepted_refs=#{result.accepted_refs.join(',')}")
      out.puts("skipped_refs=#{result.skipped_refs.join(',')}")
      out.puts("parent_automation_applied=#{result.parent_automation_applied}")
      out.puts("error=#{result.diagnostics['error']}") if result.diagnostics && result.diagnostics["error"]
    end

    def handle_show_decomposition_status(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_show_decomposition_status_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, _container|
        status = A3::Application::ShowDecompositionStatus.new(storage_dir: options.fetch(:storage_dir)).call(task_ref: options.fetch(:task_ref))
        out.puts("decomposition task=#{status.task_ref} state=#{status.state}")
        out.puts("proposal_fingerprint=#{status.proposal_fingerprint}") if status.proposal_fingerprint
        out.puts("disposition=#{status.disposition}") if status.disposition
        out.puts("blocked_reason=#{status.blocked_reason}") if status.blocked_reason && status.state == "blocked"
        status.evidence_paths.each { |key, path| out.puts("evidence.#{key}=#{path}") }
      end
    end

    def run_automatic_decomposition_draft_child_creation(session:, task:, review_result:)
      return AutomaticDraftChildCreationResult.skipped("proposal_review_not_eligible") unless review_result.success && review_result.disposition == "eligible"
      return AutomaticDraftChildCreationResult.skipped("kanban_child_writer_not_configured") unless kanban_child_writer_configured?(session.options)

      writer = A3::Infra::KanbanCliProposalChildWriter.new(
        command_argv: kanban_command_argv(session.options),
        project: session.options.fetch(:kanban_project),
        working_dir: session.options[:kanban_working_dir],
        mode: :draft
      )
      result = A3::Application::RunDecompositionChildCreation.new(
        storage_dir: session.options.fetch(:storage_dir),
        child_writer: writer,
        publish_external_task_activity: build_decomposition_source_activity_publisher(
          session.options,
          fallback: session.container.fetch(:external_task_activity_publisher)
        )
      ).call(
        task: task,
        gate: true,
        proposal_evidence_path: session.options[:proposal_evidence_path],
        review_evidence_path: review_result.evidence_path
      )
      AutomaticDraftChildCreationResult.executed(result)
    end

    AutomaticDraftChildCreationResult = Struct.new(:executed?, :skip_reason, :child_creation_result, keyword_init: true) do
      def self.skipped(reason)
        new(executed?: false, skip_reason: reason)
      end

      def self.executed(result)
        new(executed?: true, child_creation_result: result)
      end
    end

    def write_automatic_decomposition_draft_child_creation_result(out, task:, result:)
      unless result.executed?
        out.puts("decomposition draft child creation #{task.ref} skipped=#{result.skip_reason}")
        return
      end

      child_creation = result.child_creation_result
      out.puts("decomposition draft child creation #{task.ref} success=#{child_creation.success}")
      out.puts("draft_status=#{child_creation.status}") if child_creation.status
      out.puts("draft_summary=#{child_creation.summary}")
      out.puts("draft_child_refs=#{child_creation.child_refs.join(',')}")
      out.puts("draft_child_keys=#{child_creation.child_keys.join(',')}")
      out.puts("draft_evidence_path=#{child_creation.evidence_path}")
    end

    def handle_cleanup_decomposition_trial(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_cleanup_decomposition_trial_options(argv)
      result = A3::Application::CleanupDecompositionTrial.new(storage_dir: options.fetch(:storage_dir)).call(
        task_ref: options.fetch(:task_ref),
        apply: options.fetch(:apply)
      )

      out.puts("decomposition cleanup task=#{result.task_ref} mode=#{result.mode}")
      result.target_paths.each do |target|
        action = target.exists ? (result.mode == "apply" ? "delete" : "would_delete") : "none"
        out.puts("#{target.kind} path=#{target.path} exists=#{target.exists} action=#{action}")
      end
      out.puts("proposal_fingerprint=#{result.proposal_fingerprint}") if result.proposal_fingerprint
      out.puts("child_refs=#{result.child_refs.join(',')}") unless result.child_refs.empty?
      out.puts("child_keys=#{result.child_keys.join(',')}") unless result.child_keys.empty?
      result.evidence_records.each do |record|
        parts = ["evidence_file path=#{record.path}"]
        parts << "phase=#{record.phase}" if record.phase
        parts << "status=#{record.status}" if record.status
        parts << "success=#{record.success.inspect}" unless record.success.nil?
        out.puts(parts.join(" "))
      end
      out.puts("deleted_paths=#{result.deleted_paths.join(',')}")
    end

    def handle_execute_next_runnable_task(argv, out:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_execute_next_runnable_task_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner,
        worker_gateway: worker_gateway
      ) do |session|
        result = session.container.fetch(:execute_next_runnable_task).call(
          project_context: session.project_context
        )

        if result.task
          out.puts("executed next runnable #{result.task.ref} at #{result.phase}")
        else
          out.puts("no runnable task")
        end
      end
    end

    def handle_execute_until_idle(argv, out:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_execute_until_idle_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner,
        worker_gateway: worker_gateway
      ) do |session|
        result = session.container.fetch(:execute_until_idle).call(
          project_context: session.project_context,
          max_steps: session.options.fetch(:max_steps)
        )

        line = "executed #{result.executed_count} task(s); idle=#{result.idle_reached} stop_reason=#{result.stop_reason} quarantined=#{result.quarantined_count}"
        if result.scheduler_cycle && !result.scheduler_cycle.executed_steps.empty?
          line = "#{line} steps=#{result.scheduler_cycle.executed_steps.map { |step| "#{step.task_ref}:#{step.phase}" }.join(',')}"
        end
        out.puts(line)
      end
    end

    def handle_show_scheduler_state(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_storage_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        state = session.container.fetch(:show_scheduler_state).call
        out.puts("scheduler paused=#{state.paused} stop_reason=#{state.last_stop_reason} executed_count=#{state.last_executed_count}")
      end
    end

    def handle_show_state(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_storage_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        state = session.container.fetch(:show_state).call

        out.puts("scheduler paused=#{state.scheduler_state.paused} stop_reason=#{state.scheduler_state.last_stop_reason} executed_count=#{state.scheduler_state.last_executed_count}")
        out.puts("shot status=#{state.shot_state.status} pid=#{state.shot_state.pid || '-'}")
        out.puts("active_runs=#{state.active_runs.size}")
        state.active_runs.each do |run|
          out.puts("run #{run.task_ref} run_ref=#{run.run_ref} phase=#{run.phase || '-'} status=#{run.status}")
        end
        out.puts("queued_tasks=#{state.queued_tasks.size}")
        state.queued_tasks.each do |task|
          out.puts("queued #{task.task_ref} status=#{task.status} phase=#{task.phase}")
        end
        out.puts("blocked_tasks=#{state.blocked_tasks.size}")
        state.blocked_tasks.each do |task|
          out.puts("blocked #{task.task_ref}")
        end
        out.puts("repairable=#{state.repairable_items.join(',')}")
      end
    end

    def handle_repair_runs(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_repair_runs_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        result = session.container.fetch(:repair_runs).call(apply: session.options.fetch(:apply))

        out.puts("repair-runs dry_run=#{result.dry_run} actions=#{result.actions.size}")
        result.actions.each do |action|
          out.puts("repair #{action.kind} target=#{action.target_ref || '-'} applied=#{action.applied}")
        end
      end
    end

    def handle_force_stop_task(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_force_stop_task_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        result = session.container.fetch(:force_stop_run).call_task(
          task_ref: session.options.fetch(:task_ref),
          outcome: session.options.fetch(:outcome)
        )
        write_force_stop_result(out, "task", result)
      end
    end

    def handle_force_stop_run(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_force_stop_run_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        result = session.container.fetch(:force_stop_run).call_run(
          run_ref: session.options.fetch(:run_ref),
          outcome: session.options.fetch(:outcome)
        )
        write_force_stop_result(out, "run", result)
      end
    end

    def handle_show_scheduler_history(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_storage_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        history = session.container.fetch(:show_scheduler_history).call

        ShowOutputFormatter.scheduler_history_lines(history).each { |line| out.puts(line) }
      end
    end

    def handle_pause_scheduler(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_storage_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        state = session.container.fetch(:pause_scheduler).call
        out.puts("scheduler paused=true")
      end
    end

    def handle_resume_scheduler(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_storage_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        state = session.container.fetch(:resume_scheduler).call
        out.puts("scheduler paused=false")
      end
    end

    def handle_quarantine_terminal_workspaces(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_storage_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        result = session.container.fetch(:quarantine_terminal_task_workspaces).call
        out.puts("quarantined #{result.quarantined.size} workspace(s)")
      end
    end

    def handle_cleanup_terminal_workspaces(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_session(
        argv: argv,
        parse_with: :parse_cleanup_terminal_workspaces_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        result = session.container.fetch(:cleanup_terminal_task_workspaces).call(
          statuses: session.options.fetch(:statuses),
          scopes: session.options.fetch(:scopes),
          dry_run: session.options.fetch(:dry_run)
        )
        out.puts(
          "cleanup dry_run=#{result.dry_run} cleaned=#{result.cleaned.size} " \
          "statuses=#{result.statuses.join(',')} scopes=#{result.scopes.join(',')}"
        )
        result.cleaned.each do |entry|
          out.puts("#{entry.task_ref} status=#{entry.status} paths=#{entry.cleaned_paths.join(',')}")
        end
      end
    end

    def handle_prepare_workspace(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_start_run_options(argv)
      container = build_storage_container(
        options: options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      )
      task = container.fetch(:task_repository).fetch(options.fetch(:task_ref))
      result = container.fetch(:prepare_workspace).call(
        task: task,
        phase: options.fetch(:phase),
        source_descriptor: source_descriptor_for(task: task, options: options),
        scope_snapshot: container.fetch(:build_scope_snapshot).call(task: task),
        artifact_owner: container.fetch(:build_artifact_owner).call(
          task: task,
          snapshot_version: options.fetch(:source_ref)
        ),
        bootstrap_marker: options.fetch(:bootstrap_marker)
      )

      out.puts("prepared workspace #{result.workspace.root_path} for #{task.ref} at phase #{options.fetch(:phase)}")
    end

    def handle_show_project_surface(argv, out:)
      options = parse_show_project_surface_options(argv)
      surface = load_project_surface(options)

      out.puts("implementation_skill=#{surface.resolve(:implementation_skill, task_kind: options.fetch(:task_kind), repo_scope: options.fetch(:repo_scope), phase: options.fetch(:phase))}")
      if options.fetch(:task_kind) == :parent && options.fetch(:phase) == :review
        out.puts("review_skill=#{surface.resolve(:review_skill, task_kind: options.fetch(:task_kind), repo_scope: options.fetch(:repo_scope), phase: options.fetch(:phase))}")
      end
      verification_commands = Array(surface.resolve(:verification_commands, task_kind: options.fetch(:task_kind), repo_scope: options.fetch(:repo_scope), phase: options.fetch(:phase)))
      out.puts("verification_commands=#{verification_commands.join(' ')}")
    end

    def handle_show_project_context(argv, out:)
      with_manifest_session(
        argv: argv,
        parse_with: :parse_show_project_surface_options
      ) do |session|
        context = session.project_context
        options = session.options

        out.puts("merge_target=#{context.merge_config.target}")
        out.puts("merge_policy=#{context.merge_config.policy}")
        out.puts("implementation_skill=#{context.surface.resolve(:implementation_skill, task_kind: options.fetch(:task_kind), repo_scope: options.fetch(:repo_scope), phase: options.fetch(:phase))}")
      end
    end

    def handle_show_phase_runtime_config(argv, out:)
      with_manifest_session(
        argv: argv,
        parse_with: :parse_show_project_surface_options
      ) do |session|
        runtime = session.project_context.resolve_phase_runtime(task: preview_task(session.options), phase: session.options.fetch(:phase))

        out.puts("implementation_skill=#{runtime.implementation_skill}")
        out.puts("review_skill=#{runtime.review_skill}") if session.options.fetch(:task_kind) == :parent && session.options.fetch(:phase) == :review
        out.puts("review_gate_required=#{runtime.review_gate_required}")
        out.puts("merge_target=#{runtime.merge_target}")
        out.puts("merge_policy=#{runtime.merge_policy}")
      end
    end




    def handle_doctor_runtime(argv, out:)
      with_runtime_package_session(
        argv: argv,
        parse_with: :parse_show_runtime_package_options
      ) do |session|
        result = A3::Application::DoctorRuntimeEnvironment.new(
          runtime_package: session.runtime_package
        ).call
        RuntimeOutputFormatter.doctor_lines(result: result, runtime_package: session.runtime_package).each { |line| out.puts(line) }
      end
    end

    def handle_show_runtime_package(argv, out:)
      with_runtime_package_session(
        argv: argv,
        parse_with: :parse_show_runtime_package_options
      ) do |session|
        RuntimeOutputFormatter.package_lines(descriptor: session.runtime_package).each { |line| out.puts(line) }
      end
    end

    def handle_migrate_scheduler_store(argv, out:)
      with_runtime_package_session(
        argv: argv,
        parse_with: :parse_show_runtime_package_options
      ) do |session|
        result = A3::Application::MigrateSchedulerStore.new(
          runtime_package: session.runtime_package
        ).call

        out.puts("scheduler_store_migration=#{result.status}")
        out.puts("migration_state=#{result.migration_state}")
        out.puts("migration_marker_path=#{result.marker_path}")
        out.puts("message=#{result.message}")
      end
    end

    def handle_show_merge_plan(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_show_merge_plan_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        result = session.container.fetch(:build_merge_plan).call(
          task_ref: session.options.fetch(:task_ref),
          run_ref: session.options.fetch(:run_ref),
          project_context: session.project_context
        )

        out.puts("merge_source=#{result.merge_plan.merge_source.source_ref}")
        out.puts("merge_target=#{result.merge_plan.integration_target.target_ref}")
        out.puts("merge_policy=#{result.merge_plan.merge_policy}")
        out.puts("merge_slots=#{result.merge_plan.merge_slots.join(',')}")
      end
    end

    def handle_show_task(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_show_task_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        task = container.fetch(:show_task).call(task_ref: options.fetch(:task_ref))

        ShowOutputFormatter.task_lines(task).each { |line| out.puts(line) }
      end
    end

    def handle_show_run(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_runtime_package_session(
        argv: argv,
        parse_with: :parse_show_run_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |session|
        run = session.container.fetch(:show_run).call(
          run_ref: session.options.fetch(:run_ref),
          runtime_package: session.runtime_package
        )

        ShowOutputFormatter.run_lines(run).each { |line| out.puts(line) }
      end
    end

    def handle_skill_feedback_list(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_skill_feedback_list_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        entries = container.fetch(:list_skill_feedback).call(
          state: session_filter(options[:state]),
          target: session_filter(options[:target]),
          group: options.fetch(:group)
        )
        if entries.empty?
          out.puts("skill_feedback=none")
        else
          entries.each do |entry|
            if entry.respond_to?(:representative)
              representative = entry.representative
              out.puts("skill_feedback_group count=#{entry.count} #{skill_feedback_entry_parts(representative).join(' ')}")
              out.puts("skill_feedback_summary=#{representative.summary}") if representative.summary
            else
              out.puts("skill_feedback #{skill_feedback_entry_parts(entry).join(' ')}")
              out.puts("skill_feedback_summary=#{entry.summary}") if entry.summary
              out.puts("skill_feedback_suggested_patch=#{entry.suggested_patch}") if entry.suggested_patch
            end
          end
        end
      end
    end

    def handle_skill_feedback_propose(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      with_storage_container(
        argv: argv,
        parse_with: :parse_skill_feedback_propose_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        out.print(
          container.fetch(:generate_skill_feedback_proposal).call(
            state: session_filter(options[:state]) || "new",
            target: session_filter(options[:target]),
            format: options.fetch(:format)
          )
        )
      end
    end

    def handle_metrics(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      action = argv.shift
      unless %w[list summary trends].include?(action)
        raise ArgumentError, "usage: a2o metrics list|summary|trends"
      end

      with_storage_container(
        argv: argv,
        parse_with: metrics_options_parser(action),
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner
      ) do |options, container|
        reporter = container.fetch(:report_task_metrics)
        case action
        when "list"
          write_metrics_list(out, reporter.list, format: options.fetch(:format))
        when "summary"
          write_metrics_summary(out, reporter.summary(group_by: options.fetch(:group_by)), format: options.fetch(:format))
        when "trends"
          write_metrics_trends(out, reporter.trends(group_by: options.fetch(:group_by)), format: options.fetch(:format))
        end
      end
    end

    def handle_watch_summary(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_watch_summary_options(argv)
      repositories = build_watch_summary_repositories(options: options)
      task_repository = repositories.fetch(:task_repository)
      bridge = build_external_task_bridge(options)
      tasks =
        if kanban_bridge_enabled?(options)
          if bridge.task_source.respond_to?(:load_for_watch_summary)
            watch_summary_load = bridge.task_source.load_for_watch_summary
            watch_summary_warnings = watch_summary_load.warnings
            watch_summary_load.tasks
          else
            bridge.task_source.load
          end
        else
          task_repository.all
        end
      watch_summary_warnings ||= []
      task_ids = tasks.map(&:external_task_id).compact
      task_refs = tasks.reject { |task| task.external_task_id }.map(&:ref)
      kanban_snapshot_index = bridge.task_snapshot_reader.load(
        task_ids: task_ids,
        task_refs: task_refs
      )
      summary = A3::Application::ShowWatchSummary.new(
        task_repository: task_repository,
        run_repository: repositories.fetch(:run_repository),
        scheduler_state_repository: repositories.fetch(:scheduler_state_repository),
        kanban_tasks: tasks,
        kanban_snapshots_by_ref: kanban_snapshot_index.by_ref,
        kanban_snapshots_by_id: kanban_snapshot_index.by_id,
        agent_jobs_by_task_ref: load_watch_summary_agent_jobs_by_task_ref(options.fetch(:storage_dir))
      ).call
      summary.warnings.concat(watch_summary_warnings)
      attach_decomposition_entries(summary, tasks: tasks, storage_dir: options.fetch(:storage_dir))

      ShowOutputFormatter.watch_summary_lines(summary, details: options.fetch(:details)).each { |line| out.puts(line) }
    end

    def handle_run_verification(argv, out:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_show_merge_plan_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner,
        worker_gateway: worker_gateway
      ) do |session|
        result = session.container.fetch(:run_verification).call(
          task_ref: session.options.fetch(:task_ref),
          run_ref: session.options.fetch(:run_ref),
          project_context: session.project_context
        )

        out.puts("verification completed #{result.run.ref} with outcome #{result.run.terminal_outcome}")
      end
    end

    def handle_run_worker_phase(argv, out:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_show_merge_plan_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner,
        worker_gateway: worker_gateway
      ) do |session|
        result = session.container.fetch(:run_worker_phase).call(
          task_ref: session.options.fetch(:task_ref),
          run_ref: session.options.fetch(:run_ref),
          project_context: session.project_context
        )

        out.puts("worker phase completed #{result.run.ref} with outcome #{result.run.terminal_outcome}")
      end
    end

    def handle_run_merge(argv, out:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_show_merge_plan_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner,
        worker_gateway: worker_gateway
      ) do |session|
        result = session.container.fetch(:run_merge).call(
          task_ref: session.options.fetch(:task_ref),
          run_ref: session.options.fetch(:run_ref),
          project_context: session.project_context
        )

        out.puts("merge completed #{result.run.ref} with outcome #{result.run.terminal_outcome}")
      end
    end

    def handle_worker_stdin_bundle(_argv, out:)
      require "a3/operator/stdin_bundle_worker"

      exit_code = Object.new.send(:main)
      out.flush
      exit(exit_code)
    end

    def handle_root_utility(argv, out:)
      require "a3/operator/root_utility_launcher"

      exit_code = A3RootUtilityLauncher.main(argv)
      out.flush
      exit(exit_code)
    end

    def handle_agent(argv, out:)
      subject = argv.shift
      action = argv.shift
      unless subject == "package" && %w[list export verify].include?(action)
        raise ArgumentError, "usage: a2o agent package list|export|verify"
      end

      options = parse_agent_package_options(argv)
      store = A3::Infra::AgentPackageStore.new(package_dir: options.fetch(:package_dir))

      case action
      when "list"
        packages = store.list
        out.puts("agent_package_dir=#{store.package_dir}")
        if (contract = store.contract)
          out.puts("agent_package_contract schema=#{contract.schema} package_version=#{contract.package_version} runtime_version=#{contract.runtime_version} archive_manifest=#{contract.archive_manifest} launcher_layout=#{contract.launcher_layout}")
        else
          out.puts("agent_package_contract schema=legacy-runtime-manifest runtime_version=#{store.send(:inferred_runtime_version)}")
        end
        packages.each do |package|
          out.puts("target=#{package.target} version=#{package.version} archive=#{package.archive} sha256=#{package.sha256}")
        end
      when "verify"
        results = store.verify(target: options[:target])
        results.each do |result|
          out.puts("target=#{result.fetch(:target)} archive=#{result.fetch(:archive)} ok=#{result.fetch(:ok)} sha256=#{result.fetch(:actual_sha256)}")
        end
        raise A3::Domain::ConfigurationError, "agent package verification failed" unless results.all? { |result| result.fetch(:ok) }
      when "export"
        target = options.fetch(:target) { raise ArgumentError, "--target is required for agent package export" }
        output = options.fetch(:output) { raise ArgumentError, "--output is required for agent package export" }
        result = store.export(target: target, output: output)
        out.puts("agent_package_exported target=#{result.fetch(:target)} output=#{result.fetch(:output)} archive=#{result.fetch(:archive)} sha256=#{result.fetch(:sha256)}")
      end
    end

    def handle_host(argv, out:)
      action = argv.shift
      unless action == "install"
        raise ArgumentError, "usage: a2o host install --output-dir DIR"
      end

      options = parse_host_install_options(argv)
      package_dir = options.fetch(:package_dir)
      output_dir = options.fetch(:output_dir)
      share_dir = options.fetch(:share_dir)
      FileUtils.mkdir_p(output_dir)

      installed_targets = install_host_launchers(package_dir: package_dir, output_dir: output_dir)
      installed_share_dir = install_host_share_assets(share_dir: share_dir)
      install_runtime_image_reference(share_dir: share_dir, runtime_image: options[:runtime_image])
      wrapper_path = File.join(output_dir, "a2o")
      File.write(wrapper_path, host_launcher_wrapper)
      FileUtils.chmod(0o755, wrapper_path)
      remove_legacy_host_launchers(output_dir: output_dir)

      out.puts("host_launcher_installed output=#{wrapper_path} targets=#{installed_targets.join(',')}")
      out.puts("host_share_installed output=#{installed_share_dir}") if installed_share_dir
      out.puts("host_runtime_image=#{options[:runtime_image]}") if options[:runtime_image]
    end

    def handle_agent_server(argv, out:)
      options = parse_agent_server_options(argv)
      store = A3::Infra::JsonAgentJobStore.new(options.fetch(:job_store_path))
      artifact_store = A3::Infra::FileAgentArtifactStore.new(options.fetch(:artifact_store_dir))
      handler = A3::Infra::AgentHttpPullHandler.new(
        job_store: store,
        artifact_store: artifact_store,
        auth_token: options.fetch(:agent_token),
        control_auth_token: options.fetch(:agent_control_token),
        auth_token_file: options.fetch(:agent_token_file),
        control_auth_token_file: options.fetch(:agent_control_token_file)
      )
      server = A3::Infra::AgentHttpPullServer.new(
        handler: handler,
        host: options.fetch(:host),
        port: options.fetch(:port)
      )

      out.puts("agent server listening on #{options.fetch(:host)}:#{options.fetch(:port)}")
      warn("agent_server_start host=#{options.fetch(:host)} port=#{options.fetch(:port)} storage_dir=#{options.fetch(:storage_dir)} job_store=#{options.fetch(:job_store_path)} artifact_store=#{options.fetch(:artifact_store_dir)} pid=#{Process.pid}")
      begin
        server.start
      rescue StandardError => e
        warn("agent_server_fatal_error class=#{e.class} message=#{e.message} pid=#{Process.pid}")
        Array(e.backtrace).first(20).each { |line| warn("agent_server_fatal_backtrace #{line}") }
        raise
      ensure
        warn("agent_server_exit pid=#{Process.pid}")
      end
    end

    def handle_agent_artifact_cleanup(argv, out:)
      options = parse_agent_artifact_cleanup_options(argv)
      artifact_store = A3::Infra::FileAgentArtifactStore.new(options.fetch(:artifact_store_dir))
      result = artifact_store.cleanup(
        retention_seconds_by_class: options.fetch(:retention_seconds_by_class),
        max_count_by_class: options.fetch(:max_count_by_class),
        max_bytes_by_class: options.fetch(:max_bytes_by_class),
        dry_run: options.fetch(:dry_run)
      )

      out.puts("agent_artifact_cleanup=#{options.fetch(:dry_run) ? 'dry_run' : 'completed'}")
      out.puts("deleted_count=#{result.deleted_count}")
      out.puts("retained_count=#{result.retained_count}")
      out.puts("missing_blob_count=#{result.missing_blob_count}")
      out.puts("deleted_artifact_ids=#{result.deleted_artifact_ids.join(',')}") unless result.deleted_artifact_ids.empty?
      out.puts("missing_blob_artifact_ids=#{result.missing_blob_artifact_ids.join(',')}") unless result.missing_blob_artifact_ids.empty?
    end

    def handle_agent_artifact_read(argv, out:)
      options = parse_agent_artifact_read_options(argv)
      artifact_store = A3::Infra::FileAgentArtifactStore.new(options.fetch(:artifact_store_dir))
      content = artifact_store.read(options.fetch(:artifact_id))
      out.write(content)
      out.write("\n") unless content.end_with?("\n")
    end

    def handle_clear_runtime_logs(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_clear_runtime_logs_options(argv)
      repositories = build_watch_summary_repositories(options: options)
      task_repository = repositories.fetch(:task_repository)
      run_repository = repositories.fetch(:run_repository)
      artifact_store = A3::Infra::FileAgentArtifactStore.new(options.fetch(:artifact_store_dir))
      selectors = {
        task_ref: options[:task_ref],
        run_ref: options[:run_ref],
        phase: options[:phase]&.to_sym
      }.compact

      candidate_artifacts =
        if options.fetch(:all_analysis)
          artifact_store.list_metadata.select { |upload| runtime_log_roles.include?(upload.role) && upload.retention_class == :analysis }
        else
          selected_runs = run_repository.all.select do |run|
            next false if selectors[:task_ref] && run.task_ref != selectors[:task_ref]
            next false if selectors[:run_ref] && run.ref != selectors[:run_ref]
            next false if selectors[:phase] && run.phase.to_sym != selectors[:phase]

            true
          end
          active_task_refs = selected_runs.filter_map do |run|
            task = task_repository.fetch(run.task_ref)
            run.task_ref if task.current_run_ref == run.ref && !run.terminal?
          rescue A3::Domain::RecordNotFound
            nil
          end.uniq
          raise ArgumentError, "refusing to clear logs for active tasks: #{active_task_refs.join(',')}" unless active_task_refs.empty?

          selected_runs.flat_map { |run| runtime_log_artifacts_for(run) }
        end

      role_filter = Array(options[:roles]).map(&:to_s)
      candidate_artifacts = candidate_artifacts.select { |upload| role_filter.empty? || role_filter.include?(upload.role.to_s) }
      artifact_ids = candidate_artifacts.map(&:artifact_id).uniq.sort
      result = artifact_store.delete_many(artifact_ids, dry_run: !options.fetch(:apply))

      out.puts("runtime_log_clear=#{options.fetch(:apply) ? 'completed' : 'dry_run'}")
      out.puts("selector_task_ref=#{options[:task_ref]}") if options[:task_ref]
      out.puts("selector_run_ref=#{options[:run_ref]}") if options[:run_ref]
      out.puts("selector_phase=#{options[:phase]}") if options[:phase]
      out.puts("selector_all_analysis=#{options.fetch(:all_analysis)}")
      out.puts("selected_count=#{artifact_ids.size}")
      out.puts("deleted_count=#{result.fetch(:deleted_artifact_ids).size}")
      out.puts("missing_count=#{result.fetch(:missing_artifact_ids).size}")
      out.puts("selected_artifact_ids=#{artifact_ids.join(',')}") unless artifact_ids.empty?
      out.puts("missing_artifact_ids=#{result.fetch(:missing_artifact_ids).join(',')}") unless result.fetch(:missing_artifact_ids).empty?
    end

    def parse_agent_package_options(argv)
      options = {
        package_dir: A3::Infra::AgentPackageStore.default_package_dir
      }
      parser = OptionParser.new
      parser.on("--package-dir DIR") { |value| options[:package_dir] = File.expand_path(value) }
      parser.on("--target TARGET") { |value| options[:target] = value.to_s.tr("/", "-") }
      parser.on("--output PATH") { |value| options[:output] = File.expand_path(value) }
      parser.parse!(argv)
      options
    end

    def parse_host_install_options(argv)
      options = {
        package_dir: A3::Infra::AgentPackageStore.default_package_dir
      }
      parser = OptionParser.new
      parser.on("--package-dir DIR") { |value| options[:package_dir] = File.expand_path(value) }
      parser.on("--output-dir DIR") { |value| options[:output_dir] = File.expand_path(value) }
      parser.on("--share-dir DIR") { |value| options[:share_dir] = File.expand_path(value) }
      parser.on("--runtime-image IMAGE") { |value| options[:runtime_image] = value.to_s.strip }
      parser.parse!(argv)
      options.fetch(:output_dir) { raise ArgumentError, "--output-dir is required for host install" }
      options[:share_dir] ||= File.expand_path(File.join(options.fetch(:output_dir), "..", "share", "a2o"))
      options
    end

    def install_host_launchers(package_dir:, output_dir:)
      package_store = validate_host_package_dir!(package_dir)
      resolved_dir = package_store&.resolved_host_install_package_dir || package_dir
      targets = Dir.glob(File.join(resolved_dir, "*", "a2o")).sort.map do |source|
        target = File.basename(File.dirname(source))
        destination = File.join(output_dir, "a2o-#{target}")
        FileUtils.cp(source, destination)
        FileUtils.chmod(0o755, destination)
        target
      end
      raise A3::Domain::ConfigurationError, "host launcher binaries not found under #{package_dir}" if targets.empty?

      targets
    end

    def remove_legacy_host_launchers(output_dir:)
      Dir.glob(File.join(output_dir, "a3-*")).each { |path| FileUtils.rm_f(path) }
      FileUtils.rm_f(File.join(output_dir, "a3"))
    end

    def validate_host_package_dir!(package_dir)
      manifest_path = File.join(package_dir, "release-manifest.jsonl")
      contract_path = File.join(package_dir, A3::Infra::AgentPackageStore::CONTRACT_PATH)
      publication_path = File.join(package_dir, "package-publication.json")
      return nil unless File.file?(manifest_path) || File.file?(contract_path) || File.file?(publication_path)

      store = A3::Infra::AgentPackageStore.new(package_dir: package_dir)
      store.validate_runtime_compatibility!(expected_runtime_version: A3::VERSION, require_complete_host_launcher_set: true)
      resolved_dir = store.resolved_host_install_package_dir
      if resolved_dir != package_dir
        A3::Infra::AgentPackageStore.new(package_dir: resolved_dir).validate_runtime_compatibility!(expected_runtime_version: A3::VERSION)
      end
      store
    end

    def install_host_share_assets(share_dir:)
      source_dir = ENV.fetch("A2O_SHARE_DIR", ENV.fetch("A3_SHARE_DIR", "/opt/a2o/share"))
      return nil unless Dir.exist?(source_dir)

      FileUtils.mkdir_p(File.dirname(share_dir))
      FileUtils.rm_rf(share_dir)
      FileUtils.cp_r(source_dir, share_dir)
      share_dir
    end

    def install_runtime_image_reference(share_dir:, runtime_image:)
      return if runtime_image.nil? || runtime_image.empty?

      FileUtils.mkdir_p(share_dir)
      File.write(File.join(share_dir, "runtime-image"), "#{runtime_image}\n")
    end

    def host_launcher_wrapper
      <<~'SH'
        #!/usr/bin/env sh
        set -eu

        os="$(uname -s)"
        arch="$(uname -m)"
        case "$os" in
          Darwin) os_part="darwin" ;;
          Linux) os_part="linux" ;;
          *) echo "unsupported host OS: $os" >&2; exit 2 ;;
        esac
        case "$arch" in
          x86_64|amd64) arch_part="amd64" ;;
          arm64|aarch64) arch_part="arm64" ;;
          *) echo "unsupported host architecture: $arch" >&2; exit 2 ;;
        esac

        dir="$(CDPATH= cd "$(dirname "$0")" && pwd)"
        command_name="$(basename "$0")"
        case "$command_name" in
          a2o) binary="$dir/a2o-$os_part-$arch_part" ;;
          *)
            echo "removed A3 host launcher alias: $command_name; migration_required=true replacement=a2o" >&2
            exit 2
            ;;
        esac
        if [ ! -x "$binary" ]; then
          echo "A2O host launcher not found for ${os_part}-${arch_part}: $binary" >&2
          exit 1
        fi
        exec "$binary" "$@"
      SH
    end

    def parse_start_run_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        infra_diagnostics: {}
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--source-type TYPE") { |value| options[:source_type] = value }
      parser.on("--source-ref REF") { |value| options[:source_ref] = value }
      parser.on("--bootstrap-marker VALUE") { |value| options[:bootstrap_marker] = value }
      parser.on("--review-base SHA") { |value| options[:review_base] = value }
      parser.on("--review-head SHA") { |value| options[:review_head] = value }
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:phase] = remaining.fetch(1).to_sym
      options
    end

    def parse_complete_run_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {}
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:run_ref] = remaining.fetch(1)
      options[:outcome] = remaining.fetch(2).to_sym
      options
    end

    def parse_plan_rerun_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {}
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--source-type TYPE") { |value| options[:source_type] = value }
      parser.on("--source-ref REF") { |value| options[:source_ref] = value }
      parser.on("--review-base SHA") { |value| options[:review_base] = value }
      parser.on("--review-head SHA") { |value| options[:review_head] = value }
      parser.on("--snapshot-version VALUE") { |value| options[:snapshot_version] = value }
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:run_ref] = remaining.fetch(1)
      options
    end

    def parse_recover_rerun_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {}
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      parser.on("--source-type TYPE") { |value| options[:source_type] = value }
      parser.on("--source-ref REF") { |value| options[:source_ref] = value }
      parser.on("--review-base SHA") { |value| options[:review_base] = value }
      parser.on("--review-head SHA") { |value| options[:review_head] = value }
      parser.on("--snapshot-version VALUE") { |value| options[:snapshot_version] = value }
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:run_ref] = remaining.fetch(1)
      options[:manifest_path] = File.expand_path(remaining.fetch(2))
      options.fetch(:source_type)
      options.fetch(:source_ref)
      options.fetch(:review_base)
      options.fetch(:review_head)
      options.fetch(:snapshot_version)
      options
    end

    def parse_reconcile_merge_recovery_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: []
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--target-ref REF") { |value| options[:target_ref] = value }
      parser.on("--source-ref REF") { |value| options[:source_ref] = value }
      parser.on("--publish-before-head SHA") { |value| options[:publish_before_head] = value }
      parser.on("--publish-after-head SHA") { |value| options[:publish_after_head] = value }
      parser.on("--summary TEXT") { |value| options[:summary] = value }
      add_kanban_bridge_options(parser, options)
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:run_ref] = remaining.fetch(1)
      options
    end

    def parse_diagnose_blocked_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        infra_diagnostics: {}
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--expected-state VALUE") { |value| options[:expected_state] = value }
      parser.on("--observed-state VALUE") { |value| options[:observed_state] = value }
      parser.on("--failing-command VALUE") { |value| options[:failing_command] = value }
      parser.on("--diagnostic-summary VALUE") { |value| options[:diagnostic_summary] = value }
      parser.on("--infra-diagnostic KEY=VALUE") { |value| add_named_option(options[:infra_diagnostics], value, option_name: "infra diagnostic") }
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:run_ref] = remaining.fetch(1)
      options
    end

    def parse_show_blocked_diagnosis_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {}
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:run_ref] = remaining.fetch(1)
      options[:manifest_path] = File.expand_path(remaining.fetch(2))
      options
    end

    def parse_show_project_surface_options(argv)
      options = {
        preset_dir: File.expand_path("config/presets", Dir.pwd)
      }

      parser = OptionParser.new
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      parser.on("--task-kind VALUE") { |value| options[:task_kind] = value.to_sym }
      parser.on("--repo-scope VALUE") { |value| options[:repo_scope] = value.to_sym }
      parser.on("--phase VALUE") { |value| options[:phase] = value.to_sym }
      remaining = parser.parse(argv)

      options[:manifest_path] = File.expand_path(remaining.fetch(0))
      options
    end

    def parse_execute_next_runnable_task_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        verification_command_runner: nil,
        merge_runner: nil,
        worker_gateway: nil,
        worker_command_args: []
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      add_kanban_bridge_options(parser, options)
      add_verification_command_runner_options(parser, options)
      add_merge_runner_options(parser, options)
      add_worker_gateway_options(parser, options)
      remaining = parser.parse(argv)

      options[:manifest_path] = File.expand_path(remaining.fetch(0))
      options
    end

    def parse_run_decomposition_investigation_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        verification_command_runner: nil,
        merge_runner: nil,
        worker_gateway: nil,
        worker_command_args: []
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      add_kanban_bridge_options(parser, options)
      add_verification_command_runner_options(parser, options)
      add_merge_runner_options(parser, options)
      add_worker_gateway_options(parser, options)
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:manifest_path] = File.expand_path(remaining.fetch(1))
      options
    end

    def parse_run_decomposition_proposal_author_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        verification_command_runner: nil,
        merge_runner: nil,
        worker_gateway: nil,
        worker_command_args: []
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      parser.on("--investigation-evidence-path PATH") { |value| options[:investigation_evidence_path] = File.expand_path(value) }
      add_kanban_bridge_options(parser, options)
      add_verification_command_runner_options(parser, options)
      add_merge_runner_options(parser, options)
      add_worker_gateway_options(parser, options)
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:manifest_path] = File.expand_path(remaining.fetch(1))
      options[:investigation_evidence_path] ||= default_decomposition_investigation_evidence_path(
        storage_dir: options.fetch(:storage_dir),
        task_ref: options.fetch(:task_ref)
      )
      options
    end

    def parse_run_decomposition_proposal_review_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        verification_command_runner: nil,
        merge_runner: nil,
        worker_gateway: nil,
        worker_command_args: []
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      parser.on("--proposal-evidence-path PATH") { |value| options[:proposal_evidence_path] = File.expand_path(value) }
      add_kanban_bridge_options(parser, options)
      add_verification_command_runner_options(parser, options)
      add_merge_runner_options(parser, options)
      add_worker_gateway_options(parser, options)
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:manifest_path] = File.expand_path(remaining.fetch(1))
      options[:proposal_evidence_path] ||= default_decomposition_proposal_evidence_path(
        storage_dir: options.fetch(:storage_dir),
        task_ref: options.fetch(:task_ref)
      )
      options
    end

    def parse_show_decomposition_status_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {}
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      remaining = parser.parse(argv)
      options[:task_ref] = remaining.fetch(0)
      options
    end

    def parse_cleanup_decomposition_trial_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        apply: false,
        cleanup_mode: nil
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--dry-run") { options[:cleanup_mode] = register_cleanup_mode(options[:cleanup_mode], :dry_run) }
      parser.on("--apply") { options[:cleanup_mode] = register_cleanup_mode(options[:cleanup_mode], :apply) }
      remaining = parser.parse(argv)
      options[:task_ref] = remaining.fetch(0)
      options[:apply] = options[:cleanup_mode] == :apply
      options
    end

    def parse_run_decomposition_child_creation_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        gate: false
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--gate") { options[:gate] = true }
      parser.on("--proposal-evidence-path PATH") { |value| options[:proposal_evidence_path] = File.expand_path(value) }
      parser.on("--review-evidence-path PATH") { |value| options[:review_evidence_path] = File.expand_path(value) }
      options[:kanban_repo_label_map] = {}
      options[:kanban_trigger_labels] = []
      add_kanban_bridge_options(parser, options)
      remaining = parser.parse(argv)
      options[:task_ref] = remaining.fetch(0)
      if options.fetch(:gate) && (!options[:kanban_command] || !options[:kanban_project])
        raise ArgumentError, "child creation requires --kanban-command and --kanban-project when --gate is set"
      end
      options
    end

    def parse_accept_decomposition_drafts_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        child_refs: [],
        all: false,
        ready_only: false,
        remove_draft_label: false,
        parent_auto: false
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--child REF") { |value| options[:child_refs] << value }
      parser.on("--all") { options[:all] = true }
      parser.on("--ready") { options[:ready_only] = true }
      parser.on("--remove-draft-label") { options[:remove_draft_label] = true }
      parser.on("--parent-auto") { options[:parent_auto] = true }
      options[:kanban_repo_label_map] = {}
      options[:kanban_trigger_labels] = []
      add_kanban_bridge_options(parser, options)
      remaining = parser.parse(argv)
      options[:task_ref] = remaining.fetch(0)
      raise ArgumentError, "accept-decomposition-drafts requires --kanban-command and --kanban-project" unless kanban_child_writer_configured?(options)

      selector_count = [options[:all], options[:ready_only], !options[:child_refs].empty?].count(true)
      raise ArgumentError, "accept-decomposition-drafts requires exactly one selector: --child, --ready, or --all" unless selector_count == 1

      options
    end

    def parse_execute_until_idle_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        max_steps: 100,
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        verification_command_runner: nil,
        merge_runner: nil,
        worker_gateway: nil,
        worker_command_args: []
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      parser.on("--max-steps VALUE") { |value| options[:max_steps] = Integer(value) }
      add_kanban_bridge_options(parser, options)
      add_verification_command_runner_options(parser, options)
      add_merge_runner_options(parser, options)
      add_worker_gateway_options(parser, options)
      remaining = parser.parse(argv)
      options[:manifest_path] = File.expand_path(remaining.fetch(0))
      options
    end

    def parse_storage_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: []
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      add_kanban_bridge_options(parser, options)
      parser.parse(argv)

      options
    end

    def parse_watch_summary_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        details: false
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--details") { options[:details] = true }
      add_kanban_bridge_options(parser, options)
      parser.parse(argv)

      options
    end

    def parse_repair_runs_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        apply: false
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      add_kanban_bridge_options(parser, options)
      parser.on("--apply") { options[:apply] = true }
      parser.parse(argv)
      options
    end

    def parse_force_stop_task_options(argv)
      options = default_force_stop_options
      parser = force_stop_option_parser(options, "a3 force-stop-task")
      remaining = parser.parse(argv)
      raise OptionParser::MissingArgument, "--dangerous" unless options.fetch(:dangerous)

      options[:task_ref] = remaining.fetch(0)
      options
    rescue IndexError
      raise OptionParser::MissingArgument, "TASK_REF"
    end

    def parse_force_stop_run_options(argv)
      options = default_force_stop_options
      parser = force_stop_option_parser(options, "a3 force-stop-run")
      remaining = parser.parse(argv)
      raise OptionParser::MissingArgument, "--dangerous" unless options.fetch(:dangerous)

      options[:run_ref] = remaining.fetch(0)
      options
    rescue IndexError
      raise OptionParser::MissingArgument, "RUN_REF"
    end

    def default_force_stop_options
      {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        dangerous: false,
        outcome: :cancelled
      }
    end

    def force_stop_option_parser(options, banner)
      OptionParser.new do |parser|
        parser.banner = "Usage of #{banner}:"
        parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
        parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
        parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
        add_kanban_bridge_options(parser, options)
        parser.on("--outcome OUTCOME") { |value| options[:outcome] = value.to_sym }
        parser.on("--dangerous") { options[:dangerous] = true }
      end
    end

    def write_force_stop_result(out, target_kind, result)
      out.puts("force_stop_#{target_kind} task=#{result.task.ref} run=#{result.run.ref} outcome=#{result.run.terminal_outcome} already_terminal=#{result.already_terminal}")
      out.puts("force_stop_task_state status=#{result.task.status} current_run=#{result.task.current_run_ref || '-'}")
      result.stopped_jobs.each do |job|
        out.puts("force_stop_agent_job job_id=#{job.job_id} state=#{job.state}")
      end
      result.cleaned_paths.each do |path|
        out.puts("force_stop_workspace_cleanup path=#{path}")
      end
    end

    def parse_cleanup_terminal_workspaces_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        dry_run: false,
        statuses: [:done],
        scopes: %i[ticket_workspace runtime_workspace]
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      add_kanban_bridge_options(parser, options)
      parser.on("--dry-run") { options[:dry_run] = true }
      parser.on("--status LIST") { |value| options[:statuses] = parse_cleanup_list(value) }
      parser.on("--scope LIST") { |value| options[:scopes] = parse_cleanup_list(value) }
      parser.parse(argv)

      options
    end

    def parse_agent_server_options(argv)
      options = {
        storage_dir: default_storage_dir,
        host: A3::Infra::AgentHttpPullServer::DEFAULT_HOST,
        port: A3::Infra::AgentHttpPullServer::DEFAULT_PORT,
        job_store_path: nil,
        artifact_store_dir: nil,
        agent_token: canonical_agent_env("A2O_AGENT_TOKEN", "A3_AGENT_TOKEN"),
        agent_token_file: canonical_agent_env("A2O_AGENT_TOKEN_FILE", "A3_AGENT_TOKEN_FILE"),
        agent_control_token: canonical_agent_env("A2O_AGENT_CONTROL_TOKEN", "A3_AGENT_CONTROL_TOKEN"),
        agent_control_token_file: canonical_agent_env("A2O_AGENT_CONTROL_TOKEN_FILE", "A3_AGENT_CONTROL_TOKEN_FILE")
      }

      parser = OptionParser.new
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--host HOST") { |value| options[:host] = value }
      parser.on("--port PORT") { |value| options[:port] = Integer(value) }
      parser.on("--job-store PATH") { |value| options[:job_store_path] = File.expand_path(value) }
      parser.on("--artifact-store-dir DIR") { |value| options[:artifact_store_dir] = File.expand_path(value) }
      parser.on("--agent-token TOKEN") { |value| options[:agent_token] = value }
      parser.on("--agent-token-file PATH") { |value| options[:agent_token_file] = File.expand_path(value) }
      parser.on("--agent-control-token TOKEN") { |value| options[:agent_control_token] = value }
      parser.on("--agent-control-token-file PATH") { |value| options[:agent_control_token_file] = File.expand_path(value) }
      parser.parse(argv)

      options[:job_store_path] ||= File.join(options.fetch(:storage_dir), "agent_jobs.json")
      options[:artifact_store_dir] ||= File.join(options.fetch(:storage_dir), "agent_artifacts")
      options
    end

    def parse_agent_artifact_cleanup_options(argv)
      options = {
        storage_dir: default_storage_dir,
        artifact_store_dir: nil,
        dry_run: false,
        retention_seconds_by_class: {
          diagnostic: 7 * 24 * 60 * 60,
          evidence: 30 * 24 * 60 * 60
        },
        max_count_by_class: {},
        max_bytes_by_class: {}
      }

      parser = OptionParser.new
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--artifact-store-dir DIR") { |value| options[:artifact_store_dir] = File.expand_path(value) }
      parser.on("--dry-run") { options[:dry_run] = true }
      parser.on("--analysis-ttl-hours HOURS") { |value| options.fetch(:retention_seconds_by_class)[:analysis] = ttl_hours(value) }
      parser.on("--diagnostic-ttl-hours HOURS") { |value| options.fetch(:retention_seconds_by_class)[:diagnostic] = ttl_hours(value) }
      parser.on("--evidence-ttl-hours HOURS") { |value| options.fetch(:retention_seconds_by_class)[:evidence] = ttl_hours(value) }
      parser.on("--analysis-max-count COUNT") { |value| options.fetch(:max_count_by_class)[:analysis] = Integer(value) }
      parser.on("--diagnostic-max-count COUNT") { |value| options.fetch(:max_count_by_class)[:diagnostic] = Integer(value) }
      parser.on("--evidence-max-count COUNT") { |value| options.fetch(:max_count_by_class)[:evidence] = Integer(value) }
      parser.on("--analysis-max-mb MB") { |value| options.fetch(:max_bytes_by_class)[:analysis] = megabytes(value) }
      parser.on("--diagnostic-max-mb MB") { |value| options.fetch(:max_bytes_by_class)[:diagnostic] = megabytes(value) }
      parser.on("--evidence-max-mb MB") { |value| options.fetch(:max_bytes_by_class)[:evidence] = megabytes(value) }
      parser.parse(argv)

      options[:artifact_store_dir] ||= File.join(options.fetch(:storage_dir), "agent_artifacts")
      options
    end

    def parse_agent_artifact_read_options(argv)
      options = {
        storage_dir: default_storage_dir,
        artifact_store_dir: nil
      }

      parser = OptionParser.new
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--artifact-store-dir DIR") { |value| options[:artifact_store_dir] = File.expand_path(value) }
      remaining = parser.parse(argv)
      raise ArgumentError, "usage: a3 agent-artifact-read [--storage-dir DIR] ARTIFACT_ID" unless remaining.size == 1

      options[:artifact_id] = remaining.fetch(0)
      options[:artifact_store_dir] ||= File.join(options.fetch(:storage_dir), "agent_artifacts")
      options
    end

    def parse_clear_runtime_logs_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        artifact_store_dir: nil,
        task_ref: nil,
        run_ref: nil,
        phase: nil,
        roles: [],
        all_analysis: false,
        apply: false
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--artifact-store-dir DIR") { |value| options[:artifact_store_dir] = File.expand_path(value) }
      parser.on("--task-ref VALUE") { |value| options[:task_ref] = value }
      parser.on("--run-ref VALUE") { |value| options[:run_ref] = value }
      parser.on("--phase VALUE") { |value| options[:phase] = value }
      parser.on("--role VALUE") { |value| options[:roles] << value }
      parser.on("--all-analysis") { options[:all_analysis] = true }
      parser.on("--apply") { options[:apply] = true }
      parser.parse(argv)

      unless options[:all_analysis] || options[:task_ref] || options[:run_ref]
        raise ArgumentError, "provide --task-ref, --run-ref, or --all-analysis"
      end

      options[:artifact_store_dir] ||= File.join(options.fetch(:storage_dir), "agent_artifacts")
      options
    end

    def ttl_hours(value)
      (Float(value) * 60 * 60).to_i
    end

    def megabytes(value)
      (Float(value) * 1024 * 1024).to_i
    end

    def runtime_log_artifacts_for(run)
      run.phase_records.flat_map do |phase_record|
        execution = phase_record.execution_record
        next [] unless execution

        diagnostics = execution.diagnostics
        uploads = if diagnostics["agent_artifacts"].is_a?(Array)
                    diagnostics["agent_artifacts"]
                  elsif diagnostics["agent_job_result"].is_a?(Hash)
                    Array(diagnostics.dig("agent_job_result", "log_uploads")) +
                      Array(diagnostics.dig("agent_job_result", "artifact_uploads"))
                  else
                    []
                  end
        uploads.filter_map do |record|
          next unless record.is_a?(Hash)

          upload = A3::Domain::AgentArtifactUpload.from_persisted_form(record)
          upload if runtime_log_roles.include?(upload.role)
        rescue A3::Domain::ConfigurationError
          nil
        end
      end
    end

    def runtime_log_roles
      %w[combined-log ai-raw-log execution-metadata]
    end

    def parse_show_runtime_package_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {}
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      remaining = parser.parse(argv)
      options[:manifest_path] = File.expand_path(remaining.fetch(0))
      options
    end

    def parse_show_merge_plan_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {},
        kanban_repo_label_map: {},
        kanban_trigger_labels: [],
        verification_command_runner: nil,
        merge_runner: nil,
        worker_gateway: nil,
        worker_command_args: []
      }

      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      add_kanban_bridge_options(parser, options)
      add_verification_command_runner_options(parser, options)
      add_merge_runner_options(parser, options)
      add_worker_gateway_options(parser, options)
      remaining = parser.parse(argv)

      options[:task_ref] = remaining.fetch(0)
      options[:run_ref] = remaining.fetch(1)
      options[:manifest_path] = File.expand_path(remaining.fetch(2))
      options
    end

    def parse_show_task_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {}
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      remaining = parser.parse(argv)
      options[:task_ref] = remaining.fetch(0)
      options
    end

    def parse_show_run_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        preset_dir: File.expand_path("config/presets", Dir.pwd),
        repo_sources: {}
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
      remaining = parser.parse(argv)
      options[:run_ref] = remaining.fetch(0)
      options[:manifest_path] = File.expand_path(remaining.fetch(1))
      options
    end

    def parse_skill_feedback_list_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        state: nil,
        target: nil,
        group: false
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--state STATE") { |value| options[:state] = value }
      parser.on("--target TARGET") { |value| options[:target] = value }
      parser.on("--group") { options[:group] = true }
      parser.parse(argv)
      options
    end

    def parse_skill_feedback_propose_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        state: "new",
        target: nil,
        format: :ticket
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--state STATE") { |value| options[:state] = value }
      parser.on("--target TARGET") { |value| options[:target] = value }
      parser.on("--format FORMAT") { |value| options[:format] = value.to_sym }
      parser.parse(argv)
      options
    end

    def parse_metrics_list_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        format: :json
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--format FORMAT") { |value| options[:format] = metrics_format(value, allowed: %i[json csv]) }
      parser.parse(argv)
      options
    end

    def parse_metrics_summary_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        format: :text,
        group_by: :task
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--format FORMAT") { |value| options[:format] = metrics_format(value, allowed: %i[text json]) }
      parser.on("--group-by GROUP") { |value| options[:group_by] = metrics_group_by(value) }
      parser.parse(argv)
      options
    end

    def parse_metrics_trends_options(argv)
      options = {
        storage_backend: :json,
        storage_dir: default_storage_dir,
        repo_sources: {},
        format: :text,
        group_by: :all
      }
      parser = OptionParser.new
      parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
      parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
      parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
      parser.on("--format FORMAT") { |value| options[:format] = metrics_format(value, allowed: %i[text json]) }
      parser.on("--group-by GROUP") { |value| options[:group_by] = metrics_trends_group_by(value) }
      parser.parse(argv)
      options
    end

    def metrics_options_parser(action)
      case action
      when "list"
        :parse_metrics_list_options
      when "summary"
        :parse_metrics_summary_options
      when "trends"
        :parse_metrics_trends_options
      end
    end

    def metrics_format(value, allowed:)
      format = value.to_s.to_sym
      return format if allowed.include?(format)

      raise ArgumentError, "unsupported metrics format: #{value}"
    end

    def metrics_group_by(value)
      group_by = value.to_s.to_sym
      return group_by if %i[task parent].include?(group_by)

      raise ArgumentError, "unsupported metrics summary group-by: #{value}"
    end

    def metrics_trends_group_by(value)
      group_by = value.to_s.to_sym
      return group_by if %i[all task parent].include?(group_by)

      raise ArgumentError, "unsupported metrics trends group-by: #{value}"
    end

    def session_filter(value)
      value.to_s.empty? ? nil : value
    end

    def default_decomposition_investigation_evidence_path(storage_dir:, task_ref:)
      File.join(storage_dir, "decomposition-evidence", task_ref.to_s.gsub(/[^A-Za-z0-9._-]+/, "-"), "investigation.json")
    end

    def default_decomposition_proposal_evidence_path(storage_dir:, task_ref:)
      File.join(storage_dir, "decomposition-evidence", task_ref.to_s.gsub(/[^A-Za-z0-9._-]+/, "-"), "proposal.json")
    end

    def register_cleanup_mode(current_mode, next_mode)
      if current_mode && current_mode != next_mode
        raise ArgumentError, "cleanup-decomposition-trial accepts only one of --dry-run or --apply"
      end

      next_mode
    end

    def attach_decomposition_entries(summary, tasks:, storage_dir:)
      entries = tasks
        .select(&:decomposition_requested?)
        .filter_map do |task|
          status = A3::Application::ShowDecompositionStatus.new(storage_dir: storage_dir).call(task_ref: task.ref)
          next if status.state == "none"

          status
        end
      summary.define_singleton_method(:decomposition_entries) { entries.freeze }
    end

    def decomposition_task_snapshot(bridge:, task:)
      if task.external_task_id && bridge.task_source.respond_to?(:fetch_task_packet_by_external_task_id)
        return bridge.task_source.fetch_task_packet_by_external_task_id(task.external_task_id)
      end

      if bridge.task_source.respond_to?(:fetch_task_packet_by_ref)
        bridge.task_source.fetch_task_packet_by_ref(task.ref)
      end
    rescue A3::Domain::ConfigurationError, KeyError, RuntimeError
      nil
    end

    def skill_feedback_entry_parts(entry)
      parts = [
        "task=#{entry.task_ref}",
        "run=#{entry.run_ref}",
        "phase=#{entry.phase}",
        "category=#{ShowOutputFormatter::FormattingHelpers.diagnostic_value(entry.category)}",
        "target=#{ShowOutputFormatter::FormattingHelpers.diagnostic_value(entry.target)}",
        "state=#{ShowOutputFormatter::FormattingHelpers.diagnostic_value(entry.state)}"
      ]
      parts << "repo_scope=#{ShowOutputFormatter::FormattingHelpers.diagnostic_value(entry.repo_scope)}" if entry.repo_scope
      parts << "skill_path=#{ShowOutputFormatter::FormattingHelpers.diagnostic_value(entry.skill_path)}" if entry.skill_path
      parts << "confidence=#{ShowOutputFormatter::FormattingHelpers.diagnostic_value(entry.confidence)}" if entry.confidence
      parts
    end

    def write_metrics_list(out, records, format:)
      case format
      when :json
        out.puts(JSON.pretty_generate(records.map(&:persisted_form)))
      when :csv
        out.print(CSV.generate(headers: true) do |csv|
          csv << %w[task_ref parent_ref timestamp code_changes tests coverage timing cost custom]
          records.each do |record|
            csv << [
              record.task_ref,
              record.parent_ref,
              record.timestamp,
              JSON.generate(record.code_changes),
              JSON.generate(record.tests),
              JSON.generate(record.coverage),
              JSON.generate(record.timing),
              JSON.generate(record.cost),
              JSON.generate(record.custom)
            ]
          end
        end)
      else
        raise ArgumentError, "unsupported metrics list format: #{format}"
      end
    end

    def write_metrics_summary(out, entries, format:)
      case format
      when :json
        out.puts(JSON.pretty_generate(entries.map(&:persisted_form)))
      when :text
        if entries.empty?
          out.puts("metrics_summary=none")
        else
          entries.each do |entry|
            parts = entry.persisted_form.map do |key, value|
              "#{key}=#{ShowOutputFormatter::FormattingHelpers.diagnostic_value(value)}"
            end
            out.puts("metrics_summary #{parts.join(' ')}")
          end
        end
      else
        raise ArgumentError, "unsupported metrics summary format: #{format}"
      end
    end

    def write_metrics_trends(out, entries, format:)
      case format
      when :json
        out.puts(JSON.pretty_generate(entries.map(&:persisted_form)))
      when :text
        if entries.empty?
          out.puts("metrics_trends=none")
        else
          entries.each do |entry|
            parts = entry.persisted_form.map do |key, value|
              "#{key}=#{ShowOutputFormatter::FormattingHelpers.diagnostic_value(value)}"
            end
            out.puts("metrics_trends #{parts.join(' ')}")
          end
        end
      else
        raise ArgumentError, "unsupported metrics trends format: #{format}"
      end
    end

    def build_storage_container(options:, run_id_generator:, command_runner:, merge_runner:, worker_gateway: nil)
      bridge = build_external_task_bridge(options)
      storage_container(
        backend: options.fetch(:storage_backend),
        storage_dir: options.fetch(:storage_dir),
        repo_sources: options.fetch(:repo_sources),
        external_task_source: bridge.task_source,
        external_task_status_publisher: bridge.task_status_publisher,
        external_task_activity_publisher: bridge.task_activity_publisher,
        external_follow_up_child_writer: bridge.follow_up_child_writer,
        run_id_generator: run_id_generator,
        command_runner: build_command_runner(options: options, fallback: command_runner),
        merge_runner: build_merge_runner(options: options, fallback: merge_runner),
        worker_gateway: worker_gateway || build_worker_gateway(options: options, command_runner: command_runner)
      )
    end

    def build_watch_summary_repositories(options:)
      case options.fetch(:storage_backend).to_sym
      when :json
        storage_dir = options.fetch(:storage_dir)
        scheduler_store = A3::Infra::JsonSchedulerStore.new(File.join(storage_dir, "scheduler_journal.json"))
        {
          task_repository: A3::Infra::JsonTaskRepository.new(File.join(storage_dir, "tasks.json")),
          run_repository: A3::Infra::JsonRunRepository.new(File.join(storage_dir, "runs.json")),
          scheduler_state_repository: A3::Infra::JsonSchedulerStateRepository.new(scheduler_store)
        }
      when :sqlite
        db_path = File.join(options.fetch(:storage_dir), "a3.sqlite3")
        scheduler_store = A3::Infra::SqliteSchedulerStore.new(db_path)
        {
          task_repository: A3::Infra::SqliteTaskRepository.new(db_path),
          run_repository: A3::Infra::SqliteRunRepository.new(db_path),
          scheduler_state_repository: A3::Infra::SqliteSchedulerStateRepository.new(scheduler_store)
        }
      else
        raise ArgumentError, "Unsupported storage backend: #{options.fetch(:storage_backend)}"
      end
    end

    def resolve_direct_task(container: nil, task_repository: nil, external_task_source: nil, task_ref:)
      repository = task_repository || container.fetch(:task_repository)
      source = external_task_source || container.fetch(:external_task_source)
      local_task = fetch_optional_task(repository, task_ref)
      unless source.respond_to?(:fetch_by_ref)
        raise A3::Domain::RecordNotFound, "Task not found: #{task_ref}" unless local_task

        return local_task
      end

      imported_task = source.fetch_by_ref(task_ref)
      return local_task if local_task && !imported_task
      raise A3::Domain::RecordNotFound, "Task not found: #{task_ref}" unless imported_task

      repository.save(reconcile_direct_external_task(local_task, imported_task))
      repository.fetch(task_ref)
    end

    def fetch_optional_task(repository, task_ref)
      repository.fetch(task_ref)
    rescue A3::Domain::RecordNotFound
      nil
    end

    def reconcile_direct_external_task(local_task, imported_task)
      return imported_task unless local_task

      child_refs = imported_task.child_refs.any? ? imported_task.child_refs : local_task.child_refs
      parent_ref = imported_task.parent_ref || local_task.parent_ref
      kind =
        if child_refs.any?
          :parent
        elsif parent_ref
          :child
        else
          imported_task.kind
        end
      active = !local_task.current_run_ref.nil?

      A3::Domain::Task.new(
        ref: imported_task.ref,
        kind: kind,
        edit_scope: imported_task.edit_scope,
        verification_scope: imported_task.verification_scope,
        status: active ? local_task.status : imported_task.status,
        current_run_ref: local_task.current_run_ref,
        parent_ref: parent_ref,
        child_refs: child_refs,
        blocking_task_refs: imported_task.blocking_task_refs,
        priority: imported_task.priority,
        external_task_id: imported_task.external_task_id || local_task.external_task_id,
        verification_source_ref: local_task.verification_source_ref,
        automation_enabled: imported_task.automation_enabled,
        labels: imported_task.labels
      )
    end

    def load_watch_summary_agent_jobs_by_task_ref(storage_dir)
      records = load_watch_summary_agent_job_runs(storage_dir)

      records.each_with_object({}) do |record, memo|
        task_ref = String(record["task_ref"]).strip
        next if task_ref.empty?

        heartbeat_at = parse_watch_summary_time(record["heartbeat_at"])
        next unless heartbeat_at

        existing = memo[task_ref]
        existing_heartbeat_at = parse_watch_summary_time(existing && existing["heartbeat_at"])
        next if existing_heartbeat_at && existing_heartbeat_at >= heartbeat_at

        memo[task_ref] = record
      end
    end

    def load_watch_summary_agent_job_runs(storage_dir)
      path = File.join(storage_dir, "agent_jobs.json")
      return [] unless File.exist?(path)

      payload = JSON.parse(File.read(path))
      return [] unless payload.is_a?(Hash)

      payload.values.filter_map do |record|
        next unless record.is_a?(Hash)
        next unless String(record["state"]).strip == "claimed"

        request = record["request"]
        next unless request.is_a?(Hash)

        task_ref = String(request["task_ref"]).strip
        heartbeat_at = String(record["heartbeat_at"]).strip
        next if task_ref.empty? || heartbeat_at.empty?

        parsed_heartbeat_at = parse_watch_summary_time(heartbeat_at)
        next unless parsed_heartbeat_at

        {
          "task_ref" => task_ref,
          "state" => "running_command",
          "heartbeat_at" => heartbeat_at,
          "updated_at_epoch_ms" => (parsed_heartbeat_at.to_f * 1000).to_i,
          "source" => "agent_jobs",
          "job_id" => String(request["job_id"]).strip
        }
      end
    rescue JSON::ParserError, TypeError, ArgumentError
      []
    end

    def parse_watch_summary_time(raw_value)
      value = raw_value.to_s.strip
      return nil if value.empty?

      Time.iso8601(value).utc
    rescue ArgumentError
      nil
    end

    def build_bootstrap_session(options:, run_id_generator:, command_runner:, merge_runner:, worker_gateway: nil)
      bridge = build_external_task_bridge(options)
      A3::Bootstrap.session(
        manifest_path: options.fetch(:manifest_path),
        preset_dir: options.fetch(:preset_dir),
        storage_backend: options.fetch(:storage_backend),
        storage_dir: options.fetch(:storage_dir),
        repo_sources: options.fetch(:repo_sources),
        external_task_source: bridge.task_source,
        external_task_status_publisher: bridge.task_status_publisher,
        external_task_activity_publisher: bridge.task_activity_publisher,
        external_follow_up_child_writer: bridge.follow_up_child_writer,
        run_id_generator: run_id_generator,
        command_runner: build_command_runner(options: options, fallback: command_runner),
        merge_runner: build_merge_runner(options: options, fallback: merge_runner),
        worker_gateway: worker_gateway || build_worker_gateway(options: options, command_runner: command_runner)
      )
    end

    def load_project_surface(options)
      A3::Bootstrap.project_surface(
        manifest_path: options.fetch(:manifest_path),
        preset_dir: options.fetch(:preset_dir)
      )
    end

    def preview_task(options)
      A3::Domain::Task.new(
        ref: "task-preview",
        kind: options.fetch(:task_kind),
        edit_scope: expand_repo_scope(options.fetch(:repo_scope))
      )
    end

    def source_descriptor_for(task:, options:)
      A3::Domain::SourceDescriptor.new(
        workspace_kind: workspace_kind_for(options.fetch(:phase)),
        source_type: options.fetch(:source_type),
        ref: options.fetch(:source_ref),
        task_ref: task.ref
      )
    end

    def review_target_for(task:, options:)
      A3::Domain::ReviewTarget.new(
        base_commit: options.fetch(:review_base),
        head_commit: options.fetch(:review_head),
        task_ref: task.ref,
        phase_ref: :review
      )
    end

    def workspace_kind_for(phase)
      phase.to_sym == :implementation ? :ticket_workspace : :runtime_workspace
    end

    def expand_repo_scope(repo_scope)
      [repo_scope.to_sym]
    end

    def storage_container(backend:, storage_dir:, repo_sources:, external_task_source:, external_task_status_publisher:, external_task_activity_publisher:, external_follow_up_child_writer: nil, run_id_generator:, command_runner:, merge_runner:, worker_gateway: A3::Infra::LocalWorkerGateway.new)
      case backend.to_sym
      when :json
        A3::Bootstrap.json_container(storage_dir: storage_dir, repo_sources: repo_sources, external_task_source: external_task_source, external_task_status_publisher: external_task_status_publisher, external_task_activity_publisher: external_task_activity_publisher, external_follow_up_child_writer: external_follow_up_child_writer, run_id_generator: run_id_generator, command_runner: command_runner, merge_runner: merge_runner, worker_gateway: worker_gateway)
      when :sqlite
        A3::Bootstrap.sqlite_container(storage_dir: storage_dir, repo_sources: repo_sources, external_task_source: external_task_source, external_task_status_publisher: external_task_status_publisher, external_task_activity_publisher: external_task_activity_publisher, external_follow_up_child_writer: external_follow_up_child_writer, run_id_generator: run_id_generator, command_runner: command_runner, merge_runner: merge_runner, worker_gateway: worker_gateway)
      else
        raise ArgumentError, "Unsupported storage backend: #{backend}"
      end
    end

    def add_repo_source_option(options, value)
      slot, path = value.split("=", 2)
      raise ArgumentError, "repo source must be SLOT=PATH" unless slot && path

      options[:repo_sources][slot.to_sym] = File.expand_path(path)
    end

    def add_named_option(target, value, option_name:)
      key, named_value = value.split("=", 2)
      raise ArgumentError, "#{option_name} must be KEY=VALUE" unless key && named_value

      target[key] = named_value
    end

    def add_kanban_bridge_options(parser, options)
      parser.on("--kanban-backend VALUE") { |value| options[:kanban_backend] = value.to_s.strip }
      parser.on("--kanban-command VALUE") { |value| options[:kanban_command] = value }
      parser.on("--kanban-command-arg VALUE") do |value|
        options[:kanban_command_args] ||= []
        options[:kanban_command_args] << value
      end
      parser.on("--kanban-project VALUE") { |value| options[:kanban_project] = value }
      parser.on("--kanban-status VALUE") { |value| options[:kanban_status] = value }
      parser.on("--kanban-working-dir DIR") { |value| options[:kanban_working_dir] = File.expand_path(value) }
      parser.on("--kanban-blocked-label VALUE") { |value| options[:kanban_blocked_label] = value }
      parser.on("--kanban-clarification-label VALUE") { |value| options[:kanban_clarification_label] = value }
      parser.on("--kanban-follow-up-label VALUE") { |value| options[:kanban_follow_up_label] = value }
      parser.on("--kanban-trigger-label VALUE") { |value| options[:kanban_trigger_labels] << value }
      parser.on("--kanban-repo-label VALUE") { |value| add_kanban_repo_label_option(options, value) }
    end

    def add_worker_gateway_options(parser, options)
      options[:agent_token] ||= canonical_agent_env("A2O_AGENT_TOKEN", "A3_AGENT_TOKEN")
      options[:agent_token_file] ||= canonical_agent_env("A2O_AGENT_TOKEN_FILE", "A3_AGENT_TOKEN_FILE")
      options[:agent_control_token] ||= canonical_agent_env("A2O_AGENT_CONTROL_TOKEN", "A3_AGENT_CONTROL_TOKEN")
      options[:agent_control_token_file] ||= canonical_agent_env("A2O_AGENT_CONTROL_TOKEN_FILE", "A3_AGENT_CONTROL_TOKEN_FILE")
      parser.on("--worker-gateway VALUE") { |value| options[:worker_gateway] = value }
      parser.on("--worker-command VALUE") { |value| options[:worker_command] = value }
      parser.on("--worker-command-arg VALUE") { |value| options[:worker_command_args] << value }
      parser.on("--agent-control-plane-url URL") { |value| options[:agent_control_plane_url] = value }
      parser.on("--agent-token TOKEN") { |value| options[:agent_token] = value }
      parser.on("--agent-token-file PATH") { |value| options[:agent_token_file] = File.expand_path(value) }
      parser.on("--agent-control-token TOKEN") { |value| options[:agent_control_token] = value }
      parser.on("--agent-control-token-file PATH") { |value| options[:agent_control_token_file] = File.expand_path(value) }
      parser.on("--agent-allow-insecure-remote-http") { options[:agent_allow_insecure_remote] = true }
      parser.on("--agent-runtime-profile VALUE") { |value| options[:agent_runtime_profile] = value }
      parser.on("--agent-shared-workspace-mode VALUE") { |value| options[:agent_shared_workspace_mode] = value }
      parser.on("--agent-env KEY=VALUE") { |value| add_named_option(options[:agent_env] ||= {}, value, option_name: "agent env") }
      parser.on("--agent-source-alias SLOT=ALIAS") { |value| add_named_option(options[:agent_source_aliases] ||= {}, value, option_name: "agent source alias") }
      parser.on("--agent-workspace-root PATH") { |value| options[:agent_workspace_root] = value }
      parser.on("--agent-source-path ALIAS=PATH") { |value| add_named_option(options[:agent_source_paths] ||= {}, value, option_name: "agent source path") }
      parser.on("--agent-required-bin VALUE") do |value|
        options[:agent_required_bins] ||= []
        options[:agent_required_bins] << value
      end
      parser.on("--agent-support-ref SLOT=REF") { |value| add_agent_support_ref_option(options, value) }
      parser.on("--agent-workspace-freshness-policy VALUE") { |value| options[:agent_workspace_freshness_policy] = value.to_sym }
      parser.on("--agent-workspace-cleanup-policy VALUE") { |value| options[:agent_workspace_cleanup_policy] = value.to_sym }
      parser.on("--agent-job-timeout-seconds VALUE") { |value| options[:agent_job_timeout_seconds] = Integer(value) }
      parser.on("--agent-job-poll-interval-seconds VALUE") { |value| options[:agent_job_poll_interval_seconds] = Float(value) }
    end

    def add_verification_command_runner_options(parser, options)
      parser.on("--verification-command-runner VALUE") { |value| options[:verification_command_runner] = value }
    end

    def add_merge_runner_options(parser, options)
      parser.on("--merge-runner VALUE") { |value| options[:merge_runner] = value }
    end

    def parse_cleanup_list(value)
      value.split(",").map(&:strip).reject(&:empty?).map(&:to_sym)
    end

    def default_storage_dir
      File.expand_path("tmp/a3", Dir.pwd)
    end

    def add_kanban_repo_label_option(options, value)
      label, scopes = value.split("=", 2)
      raise ArgumentError, "kanban repo label must be LABEL=SCOPE[,SCOPE]" unless label && scopes

      options[:kanban_repo_label_map][label] = scopes.split(",").map(&:strip).reject(&:empty?)
    end

    def repo_scope_aliases_from_kanban_label_map(repo_label_map)
      repo_label_map.each_with_object({}) do |(label, scopes), aliases|
        normalized_scopes = Array(scopes).map(&:to_s).reject(&:empty?)
        aliases[label] =
          if normalized_scopes.size == 1
            normalized_scopes.first
          else
            label.to_s.include?(":") ? label.to_s.split(":", 2).last : label.to_s
          end
      end
    end

    def review_disposition_slot_scopes_from_kanban_label_map(repo_label_map)
      scopes = repo_label_map.flat_map do |_label, values|
        Array(values).map(&:to_s).reject(&:empty?)
      end.uniq
      scopes.empty? ? nil : scopes
    end

    def repo_scope_expansions_from_kanban_label_map(repo_label_map)
      repo_label_map.each_with_object({}) do |(label, scopes), expansions|
        normalized_scopes = Array(scopes).map(&:to_s).reject(&:empty?)
        next unless normalized_scopes.size > 1

        alias_scope = repo_scope_aliases_from_kanban_label_map({ label => normalized_scopes }).fetch(label)
        expansions[alias_scope] = normalized_scopes
      end
    end

    def build_external_task_bridge(options)
      validate_kanban_bridge_options!(options)
      return A3::Infra::KanbanBridgeBundle.new(
        task_source: A3::Infra::NullExternalTaskSource.new,
        task_status_publisher: A3::Infra::NullExternalTaskStatusPublisher.new,
        task_activity_publisher: A3::Infra::NullExternalTaskActivityPublisher.new,
        follow_up_child_writer: nil,
        task_snapshot_reader: A3::Infra::NullExternalTaskSnapshotReader.new
      ) unless kanban_bridge_enabled?(options)

      case kanban_backend(options)
      when "subprocess-cli"
        command_argv = kanban_command_argv(options)
        project = options.fetch(:kanban_project)
        working_dir = options[:kanban_working_dir]
        A3::Infra::KanbanBridgeBundle.new(
          task_source: A3::Infra::KanbanCliTaskSource.new(
            command_argv: command_argv,
            project: project,
            repo_label_map: options.fetch(:kanban_repo_label_map),
            trigger_labels: options.fetch(:kanban_trigger_labels),
            blocked_label: options.fetch(:kanban_blocked_label, "blocked"),
            clarification_label: options.fetch(:kanban_clarification_label, "needs:clarification"),
            status: options[:kanban_status],
            working_dir: working_dir
          ),
          task_status_publisher: A3::Infra::KanbanCliTaskStatusPublisher.new(
            command_argv: command_argv,
            project: project,
            blocked_label: options.fetch(:kanban_blocked_label, "blocked"),
            clarification_label: options.fetch(:kanban_clarification_label, "needs:clarification"),
            working_dir: working_dir
          ),
          task_activity_publisher: A3::Infra::KanbanCliTaskActivityPublisher.new(
            command_argv: command_argv,
            project: project,
            working_dir: working_dir
          ),
          follow_up_child_writer: A3::Infra::KanbanCliFollowUpChildWriter.new(
            command_argv: command_argv,
            project: project,
            repo_label_map: options.fetch(:kanban_repo_label_map),
            repo_scope_expansions: repo_scope_expansions_from_kanban_label_map(options.fetch(:kanban_repo_label_map)),
            follow_up_label: options[:kanban_follow_up_label],
            working_dir: working_dir
          ),
          task_snapshot_reader: A3::Infra::KanbanCliTaskSnapshotReader.new(
            command_argv: command_argv,
            project: project,
            working_dir: working_dir
          )
        )
      else
        raise ArgumentError, "Unsupported kanban backend: #{kanban_backend(options)}"
      end
    end

    def build_external_task_source(options)
      build_external_task_bridge(options).task_source
    end

    def build_external_task_status_publisher(options)
      build_external_task_bridge(options).task_status_publisher
    end

    def build_external_task_activity_publisher(options)
      build_external_task_bridge(options).task_activity_publisher
    end

    def build_decomposition_source_activity_publisher(options, fallback: nil)
      return build_kanban_cli_task_activity_publisher(options) if kanban_child_writer_configured?(options)

      fallback || A3::Infra::NullExternalTaskActivityPublisher.new
    end

    def build_kanban_cli_task_activity_publisher(options)
      case kanban_backend(options)
      when "subprocess-cli"
        A3::Infra::KanbanCliTaskActivityPublisher.new(
          command_argv: kanban_command_argv(options),
          project: options.fetch(:kanban_project),
          working_dir: options[:kanban_working_dir]
        )
      else
        raise ArgumentError, "Unsupported kanban backend: #{kanban_backend(options)}"
      end
    end

    def kanban_backend(options)
      backend = options[:kanban_backend].to_s.strip
      backend.empty? ? "subprocess-cli" : backend
    end

    def build_worker_gateway(options:, command_runner:)
      gateway = options[:worker_gateway].to_s
      return A3::Infra::DisabledWorkerGateway.new if gateway.empty?
      return A3::Infra::LocalWorkerGateway.new(
        command_runner: command_runner,
        worker_command: options[:worker_command],
        worker_command_args: options.fetch(:worker_command_args, []),
        worker_protocol: A3::Infra::WorkerProtocol.new(
          repo_scope_aliases: repo_scope_aliases_from_kanban_label_map(options.fetch(:kanban_repo_label_map, {})),
          review_disposition_slot_scopes: review_disposition_slot_scopes_from_kanban_label_map(options.fetch(:kanban_repo_label_map, {}))
        )
      ) if gateway == "local"

      if gateway == "agent-http"
        raise ArgumentError, "--agent-control-plane-url is required for --worker-gateway agent-http" unless options[:agent_control_plane_url]
        validate_agent_control_plane_url!(options.fetch(:agent_control_plane_url), allow_insecure_remote: options.fetch(:agent_allow_insecure_remote, false))
        shared_workspace_mode = options[:agent_shared_workspace_mode]
        unless %w[same-path agent-materialized].include?(shared_workspace_mode)
          raise ArgumentError, "--agent-shared-workspace-mode same-path or agent-materialized is required for --worker-gateway agent-http"
        end

        return A3::Infra::AgentWorkerGateway.new(
          control_plane_client: A3::Infra::AgentControlPlaneClient.new(
            base_url: options.fetch(:agent_control_plane_url),
            auth_token: agent_control_auth_token(options)
          ),
          worker_command: options[:worker_command],
          worker_command_args: options.fetch(:worker_command_args, []),
          runtime_profile: options.fetch(:agent_runtime_profile, "default"),
          shared_workspace_mode: shared_workspace_mode,
          timeout_seconds: options.fetch(:agent_job_timeout_seconds, 1800),
          poll_interval_seconds: options.fetch(:agent_job_poll_interval_seconds, 1.0),
          worker_protocol: A3::Infra::WorkerProtocol.new(
            repo_scope_aliases: repo_scope_aliases_from_kanban_label_map(options.fetch(:kanban_repo_label_map, {})),
            review_disposition_slot_scopes: review_disposition_slot_scopes_from_kanban_label_map(options.fetch(:kanban_repo_label_map, {}))
          ),
          workspace_request_builder: agent_workspace_request_builder(options),
          env: options.fetch(:agent_env, {}),
          agent_environment: agent_environment_from_options(options)
        )
      end

      raise ArgumentError, "Unsupported worker gateway: #{gateway}"
    end

    def build_command_runner(options:, fallback:)
      runner = options[:verification_command_runner].to_s
      return fallback if runner.empty?
      return fallback if runner == "local"

      if runner == "agent-http"
        raise ArgumentError, "--agent-control-plane-url is required for --verification-command-runner agent-http" unless options[:agent_control_plane_url]
        validate_agent_control_plane_url!(options.fetch(:agent_control_plane_url), allow_insecure_remote: options.fetch(:agent_allow_insecure_remote, false))
        shared_workspace_mode = options[:agent_shared_workspace_mode]
        unless %w[same-path agent-materialized].include?(shared_workspace_mode)
          raise ArgumentError, "--agent-shared-workspace-mode same-path or agent-materialized is required for --verification-command-runner agent-http"
        end

        return A3::Infra::AgentCommandRunner.new(
          control_plane_client: A3::Infra::AgentControlPlaneClient.new(
            base_url: options.fetch(:agent_control_plane_url),
            auth_token: agent_control_auth_token(options)
          ),
          runtime_profile: options.fetch(:agent_runtime_profile, "default"),
          shared_workspace_mode: shared_workspace_mode,
          timeout_seconds: options.fetch(:agent_job_timeout_seconds, 1800),
          poll_interval_seconds: options.fetch(:agent_job_poll_interval_seconds, 1.0),
          workspace_request_builder: agent_workspace_request_builder(options),
          env: options.fetch(:agent_env, {}),
          agent_environment: agent_environment_from_options(options)
        )
      end

      raise ArgumentError, "Unsupported verification command runner: #{runner}"
    end

    def build_merge_runner(options:, fallback:)
      runner = options[:merge_runner].to_s
      return fallback if runner.empty?
      return fallback if runner == "local"

      if runner == "agent-http"
        raise ArgumentError, "--agent-control-plane-url is required for --merge-runner agent-http" unless options[:agent_control_plane_url]
        validate_agent_control_plane_url!(options.fetch(:agent_control_plane_url), allow_insecure_remote: options.fetch(:agent_allow_insecure_remote, false))
        source_aliases = options.fetch(:agent_source_aliases, {})
        raise ArgumentError, "--agent-source-alias is required for --merge-runner agent-http" if source_aliases.empty?

        return A3::Infra::AgentMergeRunner.new(
          control_plane_client: A3::Infra::AgentControlPlaneClient.new(
            base_url: options.fetch(:agent_control_plane_url),
            auth_token: agent_control_auth_token(options)
          ),
          runtime_profile: options.fetch(:agent_runtime_profile, "default"),
          source_aliases: source_aliases,
          timeout_seconds: options.fetch(:agent_job_timeout_seconds, 1800),
          poll_interval_seconds: options.fetch(:agent_job_poll_interval_seconds, 1.0),
          agent_environment: agent_environment_from_options(options),
          merge_recovery_command: options[:worker_command],
          merge_recovery_args: options.fetch(:worker_command_args, []),
          merge_recovery_env: options.fetch(:agent_env, {})
        )
      end

      raise ArgumentError, "Unsupported merge runner: #{runner}"
    end

    def agent_auth_token(options)
      token = options.fetch(:agent_token, "").to_s
      return token unless token.empty?

      token_file = options.fetch(:agent_token_file, "").to_s
      return "" if token_file.empty?

      read_token_file(token_file, label: "agent token")
    end

    def agent_control_auth_token(options)
      token = options.fetch(:agent_control_token, "").to_s
      return token unless token.empty?

      token_file = options.fetch(:agent_control_token_file, "").to_s
      return agent_auth_token(options) if token_file.empty?

      read_token_file(token_file, label: "agent control token")
    end

    def read_token_file(token_file, label:)
      content = File.read(token_file).strip
      raise ArgumentError, "#{label} file is empty: #{token_file}" if content.empty?

      content
    end

    def canonical_agent_env(canonical_name, legacy_name)
      if ENV.fetch(legacy_name, "").strip != ""
        raise KeyError,
              "removed A3 compatibility input: environment variable #{legacy_name}; migration_required=true replacement=environment variable #{canonical_name}"
      end

      ENV.fetch(canonical_name, "")
    end

    def agent_workspace_request_builder(options)
      return nil unless options[:agent_shared_workspace_mode] == "agent-materialized"

      source_aliases = options.fetch(:agent_source_aliases, {})
      raise ArgumentError, "--agent-source-alias is required for --agent-shared-workspace-mode agent-materialized" if source_aliases.empty?
      repo_source_slots = options.fetch(:repo_sources, {}).keys
      repo_source_slots = nil if repo_source_slots.empty?

      A3::Infra::AgentWorkspaceRequestBuilder.new(
        source_aliases: source_aliases,
        repo_slot_policy: A3::Infra::AgentWorkspaceRepoPolicy.new(
          available_slots: source_aliases.keys,
          required_slots: repo_source_slots
        ),
        freshness_policy: options.fetch(:agent_workspace_freshness_policy, :reuse_if_clean_and_ref_matches),
        cleanup_policy: options.fetch(:agent_workspace_cleanup_policy, :retain_until_a3_cleanup),
        support_ref: options[:agent_support_ref],
        support_refs: options.fetch(:agent_support_refs, {})
      )
    end

    def agent_environment_from_options(options)
      validate_agent_env!(options.fetch(:agent_env, {}))
      environment = {}
      workspace_root = options[:agent_workspace_root].to_s
      environment["workspace_root"] = workspace_root unless workspace_root.empty?

      source_paths = options.fetch(:agent_source_paths, {})
      environment["source_paths"] = source_paths.transform_keys(&:to_s).transform_values(&:to_s) unless source_paths.empty?

      env = options.fetch(:agent_env, {})
      environment["env"] = env.transform_keys(&:to_s).transform_values(&:to_s) unless env.empty?

      required_bins = Array(options[:agent_required_bins]).map(&:to_s).reject(&:empty?)
      environment["required_bins"] = required_bins unless required_bins.empty?

      environment.empty? ? nil : environment
    end

    def validate_agent_env!(env)
      return unless env.transform_keys(&:to_s).key?("A3_ROOT_DIR")

      raise KeyError,
            "removed A3 root utility input: environment variable A3_ROOT_DIR; migration_required=true replacement=environment variable A2O_ROOT_DIR"
    end

    def add_agent_support_ref_option(options, value)
      raw = value.to_s
      if raw.include?("=")
        add_named_option(options[:agent_support_refs] ||= {}, raw, option_name: "agent support ref")
      else
        options[:agent_support_ref] = raw
      end
    end

    def validate_agent_control_plane_url!(raw_url, allow_insecure_remote:)
      uri = URI(raw_url.to_s)
      return unless uri.scheme == "http"
      return if allow_insecure_remote || local_http_host?(uri.host)

      raise ArgumentError, "--agent-control-plane-url uses remote HTTP; current A2O supports local topology only, use loopback/compose service URL or set --agent-allow-insecure-remote-http for an explicit diagnostic exception"
    end

    def local_http_host?(host)
      normalized = host.to_s.downcase.strip
      return true if normalized.empty? || normalized == "localhost"
      return true if normalized.match?(/\A127(?:\.\d{1,3}){3}\z/)
      return true if normalized == "::1"

      !normalized.include?(".")
    end

    def kanban_bridge_enabled?(options)
      options[:kanban_command] && options[:kanban_project] && !options.fetch(:kanban_repo_label_map, {}).empty?
    end

    def kanban_child_writer_configured?(options)
      options[:kanban_command] && options[:kanban_project]
    end

    def kanban_command_argv(options)
      [options.fetch(:kanban_command), *Array(options[:kanban_command_args])]
    end

    def validate_kanban_bridge_options!(options)
      provided_keys = []
      provided_keys << :kanban_backend if options[:kanban_backend]
      provided_keys << :kanban_command if options[:kanban_command]
      provided_keys << :kanban_project if options[:kanban_project]
      provided_keys << :kanban_status if options[:kanban_status]
      provided_keys << :kanban_repo_label_map unless options.fetch(:kanban_repo_label_map, {}).empty?
      provided_keys << :kanban_trigger_labels unless options.fetch(:kanban_trigger_labels, []).empty?
      provided_keys << :kanban_working_dir if options[:kanban_working_dir]
      provided_keys << :kanban_blocked_label if options[:kanban_blocked_label]
      provided_keys << :kanban_clarification_label if options[:kanban_clarification_label]
      return if provided_keys.empty? || kanban_bridge_enabled?(options)
      child_writer_only_keys = %i[kanban_backend kanban_command kanban_project kanban_working_dir]
      return if kanban_child_writer_configured?(options) && (provided_keys - child_writer_only_keys).empty?

      raise ArgumentError,
        "kanban bridge options require --kanban-command, --kanban-project, and at least one --kanban-repo-label"
    end

  end
end
