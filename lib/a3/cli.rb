# frozen_string_literal: true

require "optparse"
require "pathname"
require "shellwords"
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
        out.puts("A3 CLI placeholder: #{argv.join(' ')}")
      end
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
        out.puts("runtime_package_runtime_canary_command=#{result.recovery.runtime_package_runtime_canary_command}") if result.recovery.runtime_package_runtime_canary_command
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
      ) do |_options, container|
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
      out.puts("verification_commands=#{surface.verification_commands.join(' ')}")
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

    def handle_watch_summary(argv, out:, run_id_generator:, command_runner:, merge_runner:)
      options = parse_storage_options(argv)
      repositories = build_watch_summary_repositories(options: options)
      task_repository = repositories.fetch(:task_repository)
      tasks = task_repository.all
      task_ids = tasks.map(&:external_task_id).compact
      task_refs = tasks.reject { |task| task.external_task_id }.map(&:ref)
      kanban_snapshot_index = build_external_task_bridge(options).task_snapshot_reader.load(
        task_ids: task_ids,
        task_refs: task_refs
      )
      summary = A3::Application::ShowWatchSummary.new(
        task_repository: task_repository,
        run_repository: repositories.fetch(:run_repository),
        scheduler_state_repository: repositories.fetch(:scheduler_state_repository),
        kanban_snapshots_by_ref: kanban_snapshot_index.by_ref,
        kanban_snapshots_by_id: kanban_snapshot_index.by_id
      ).call

      ShowOutputFormatter.watch_summary_lines(summary).each { |line| out.puts(line) }
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

    def handle_run_runtime_canary(argv, out:, run_id_generator:, command_runner:, merge_runner:, worker_gateway:)
      with_runtime_session(
        argv: argv,
        parse_with: :parse_execute_until_idle_options,
        run_id_generator: run_id_generator,
        command_runner: command_runner,
        merge_runner: merge_runner,
        worker_gateway: worker_gateway
      ) do |session|
        result = A3::Application::RunRuntimeCanary.new(
          runtime_package: session.runtime_package,
          execute_until_idle: session.container.fetch(:execute_until_idle)
        ).call(
          project_context: session.project_context,
          max_steps: session.options.fetch(:max_steps)
        )

        RuntimeOutputFormatter.canary_lines(result: result, runtime_package: session.runtime_package).each { |line| out.puts(line) }
      end
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
      server.start
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
        agent_token: ENV.fetch("A3_AGENT_TOKEN", ""),
        agent_token_file: ENV.fetch("A3_AGENT_TOKEN_FILE", ""),
        agent_control_token: ENV.fetch("A3_AGENT_CONTROL_TOKEN", ""),
        agent_control_token_file: ENV.fetch("A3_AGENT_CONTROL_TOKEN_FILE", "")
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
      parser.on("--diagnostic-ttl-hours HOURS") { |value| options.fetch(:retention_seconds_by_class)[:diagnostic] = ttl_hours(value) }
      parser.on("--evidence-ttl-hours HOURS") { |value| options.fetch(:retention_seconds_by_class)[:evidence] = ttl_hours(value) }
      parser.on("--diagnostic-max-count COUNT") { |value| options.fetch(:max_count_by_class)[:diagnostic] = Integer(value) }
      parser.on("--evidence-max-count COUNT") { |value| options.fetch(:max_count_by_class)[:evidence] = Integer(value) }
      parser.on("--diagnostic-max-mb MB") { |value| options.fetch(:max_bytes_by_class)[:diagnostic] = megabytes(value) }
      parser.on("--evidence-max-mb MB") { |value| options.fetch(:max_bytes_by_class)[:evidence] = megabytes(value) }
      parser.parse(argv)

      options[:artifact_store_dir] ||= File.join(options.fetch(:storage_dir), "agent_artifacts")
      options
    end

    def ttl_hours(value)
      (Float(value) * 60 * 60).to_i
    end

    def megabytes(value)
      (Float(value) * 1024 * 1024).to_i
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
      parser.on("--kanban-follow-up-label VALUE") { |value| options[:kanban_follow_up_label] = value }
      parser.on("--kanban-trigger-label VALUE") { |value| options[:kanban_trigger_labels] << value }
      parser.on("--kanban-repo-label VALUE") { |value| add_kanban_repo_label_option(options, value) }
    end

    def add_worker_gateway_options(parser, options)
      options[:agent_token] ||= ENV.fetch("A3_AGENT_TOKEN", "")
      options[:agent_token_file] ||= ENV.fetch("A3_AGENT_TOKEN_FILE", "")
      options[:agent_control_token] ||= ENV.fetch("A3_AGENT_CONTROL_TOKEN", "")
      options[:agent_control_token_file] ||= ENV.fetch("A3_AGENT_CONTROL_TOKEN_FILE", "")
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
      value.split(",").map { |entry| entry.strip.tr("-", "_") }.reject(&:empty?).map(&:to_sym)
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

    def review_disposition_repo_scopes_from_kanban_label_map(repo_label_map)
      scopes = repo_label_map.flat_map do |label, values|
        normalized_values = Array(values).map(&:to_s).reject(&:empty?)
        alias_scope = repo_scope_aliases_from_kanban_label_map({ label => normalized_values }).fetch(label, nil)
        normalized_values + Array(alias_scope)
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
            status: options[:kanban_status],
            working_dir: working_dir
          ),
          task_status_publisher: A3::Infra::KanbanCliTaskStatusPublisher.new(
            command_argv: command_argv,
            project: project,
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
          review_disposition_repo_scopes: review_disposition_repo_scopes_from_kanban_label_map(options.fetch(:kanban_repo_label_map, {}))
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
            review_disposition_repo_scopes: review_disposition_repo_scopes_from_kanban_label_map(options.fetch(:kanban_repo_label_map, {}))
          ),
          workspace_request_builder: agent_workspace_request_builder(options),
          env: options.fetch(:agent_env, {})
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
          env: options.fetch(:agent_env, {})
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
          poll_interval_seconds: options.fetch(:agent_job_poll_interval_seconds, 1.0)
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

    def agent_workspace_request_builder(options)
      return nil unless options[:agent_shared_workspace_mode] == "agent-materialized"

      source_aliases = options.fetch(:agent_source_aliases, {})
      raise ArgumentError, "--agent-source-alias is required for --agent-shared-workspace-mode agent-materialized" if source_aliases.empty?

      A3::Infra::AgentWorkspaceRequestBuilder.new(
        source_aliases: source_aliases,
        freshness_policy: options.fetch(:agent_workspace_freshness_policy, :reuse_if_clean_and_ref_matches),
        cleanup_policy: options.fetch(:agent_workspace_cleanup_policy, :retain_until_a3_cleanup),
        support_ref: options[:agent_support_ref],
        support_refs: options.fetch(:agent_support_refs, {})
      )
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

      raise ArgumentError, "--agent-control-plane-url uses remote HTTP; current A3 supports local topology only, use loopback/compose service URL or set --agent-allow-insecure-remote-http for an explicit diagnostic exception"
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
      return if provided_keys.empty? || kanban_bridge_enabled?(options)

      raise ArgumentError,
        "kanban bridge options require --kanban-command, --kanban-project, and at least one --kanban-repo-label"
    end

  end
end
