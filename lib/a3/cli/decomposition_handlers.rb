# frozen_string_literal: true

require "optparse"

module A3
  module CLI
    module DecompositionHandlers
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
          publish_decomposition_source_status(session: session, task: task, status: :in_progress)
          bridge = build_external_task_bridge(session.options)
          process_runner = build_decomposition_process_runner(options: session.options, task_ref: task.ref, stage: :investigate)
          result = A3::Application::RunDecompositionInvestigation.new(
            storage_dir: session.options.fetch(:storage_dir),
            project_root: File.dirname(session.options.fetch(:manifest_path)),
            process_runner: process_runner,
            progress_io: out,
            publish_external_task_activity: session.container.fetch(:external_task_activity_publisher),
            host_shared_root: session.options[:host_shared_root],
            container_shared_root: session.options[:container_shared_root],
            command_workspace_dir: session.options[:decomposition_workspace_dir]
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
          publish_decomposition_source_status(session: session, task: task, status: :in_progress)
          process_runner = build_decomposition_process_runner(options: session.options, task_ref: task.ref, stage: :propose)
          runner = A3::Application::RunDecompositionProposalAuthor.new(
            storage_dir: session.options.fetch(:storage_dir),
            project_root: File.dirname(session.options.fetch(:manifest_path)),
            process_runner: process_runner,
            host_shared_root: session.options[:host_shared_root],
            container_shared_root: session.options[:container_shared_root],
            command_workspace_dir: session.options[:decomposition_workspace_dir],
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
          publish_decomposition_source_status(session: session, task: task, status: :in_review)
          process_runner = build_decomposition_process_runner(options: session.options, task_ref: task.ref, stage: :review)
          result = A3::Application::RunDecompositionProposalReview.new(
            storage_dir: session.options.fetch(:storage_dir),
            project_root: File.dirname(session.options.fetch(:manifest_path)),
            process_runner: process_runner,
            host_shared_root: session.options[:host_shared_root],
            container_shared_root: session.options[:container_shared_root],
            command_workspace_dir: session.options[:decomposition_workspace_dir],
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
          review_evidence_path: options[:review_evidence_path],
          source_remote: source_remote_for_task(task: task, external_task_source: external_task_source)
        )

        if result.success.nil? && result.status == "gate_closed"
          out.puts("decomposition child creation #{task.ref} status=#{result.status}")
          out.puts("child_creation_result=not_attempted")
        else
          out.puts("decomposition child creation #{task.ref} success=#{result.success}")
          out.puts("status=#{result.status}") if result.status
        end
        out.puts("summary=#{result.summary}")
        publish_decomposition_source_status_from_options(options: options, task: task, status: decomposition_source_terminal_status(result)) if result.success == true
        out.puts("generated_parent_ref=#{result.respond_to?(:parent_ref) && result.parent_ref}") if result.respond_to?(:parent_ref) && result.parent_ref
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
        scheduler_guard = enter_accept_drafts_scheduler_guard(repositories.fetch(:scheduler_state_repository))
        result = writer.call(
          parent_task_ref: task.ref,
          parent_external_task_id: task.external_task_id,
          child_refs: options.fetch(:child_refs),
          all: options.fetch(:all),
          ready_only: options.fetch(:ready_only),
          remove_draft_label: options.fetch(:remove_draft_label),
          parent_auto: options.fetch(:parent_auto)
        )
        scheduler_guard = resume_accept_drafts_scheduler_guard(
          repositories.fetch(:scheduler_state_repository),
          scheduler_guard
        ) if result.success?

        out.puts("decomposition draft acceptance #{task.ref} success=#{result.success?}")
        out.puts("scheduler_guard=#{scheduler_guard.fetch(:status)}")
        out.puts("scheduler_guard_resumed=#{scheduler_guard.fetch(:resumed)}")
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
          out.puts("stage=#{status.stage}") if status.stage
          out.puts("proposal_fingerprint=#{status.proposal_fingerprint}") if status.proposal_fingerprint
          out.puts("disposition=#{status.disposition}") if status.disposition
          out.puts("blocked_reason=#{status.blocked_reason}") if status.blocked_reason && status.state == "blocked"
          status.evidence_paths.each { |key, path| out.puts("evidence.#{key}=#{path}") }
        end
      end

      def run_automatic_decomposition_draft_child_creation(session:, task:, review_result:)
        unless review_result.success && review_result.disposition == "eligible"
          terminal_status = decomposition_review_terminal_status(review_result)
          if terminal_status
            publish_decomposition_source_status(
              session: session,
              task: task,
              status: terminal_status,
              status_reason: review_result.summary,
              status_details: decomposition_review_status_details(review_result)
            )
          end
          return AutomaticDraftChildCreationResult.skipped("proposal_review_not_eligible")
        end
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
          review_evidence_path: review_result.evidence_path,
          source_remote: source_remote_for_task(task: task, external_task_source: session.container[:external_task_source])
        )
        publish_decomposition_source_status(session: session, task: task, status: decomposition_source_terminal_status(result)) if result.success == true
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
        out.puts("draft_parent_ref=#{child_creation.parent_ref}") if child_creation.respond_to?(:parent_ref) && child_creation.parent_ref
        out.puts("draft_child_refs=#{child_creation.child_refs.join(',')}")
        out.puts("draft_child_keys=#{child_creation.child_keys.join(',')}")
        out.puts("draft_evidence_path=#{child_creation.evidence_path}")
      end

      def publish_decomposition_source_status(session:, task:, status:, status_reason: nil, status_details: nil)
        publisher = session.container.fetch(:external_task_status_publisher, A3::Infra::NullExternalTaskStatusPublisher.new)
        payload = {
          task_ref: task.ref,
          external_task_id: task.external_task_id,
          status: status,
          task_kind: task.kind
        }
        payload[:status_reason] = status_reason if status_reason
        payload[:status_details] = status_details if status_details
        publisher.publish(**payload)
      end

      def publish_decomposition_source_status_from_options(options:, task:, status:)
        return unless kanban_child_writer_configured?(options)

        build_decomposition_source_status_publisher(options).publish(
          task_ref: task.ref,
          external_task_id: task.external_task_id,
          status: status,
          task_kind: task.kind
        )
      end

      def decomposition_source_terminal_status(result)
        result.respond_to?(:status) && result.status == "needs_clarification" ? :needs_clarification : :done
      end

      def decomposition_review_terminal_status(result)
        result.disposition == "blocked" ? :blocked : nil
      end

      def decomposition_review_status_details(result)
        {
          "disposition" => result.disposition,
          "critical_findings" => Array(result.critical_findings).map do |finding|
            finding.is_a?(Hash) ? finding.slice("severity", "summary", "details") : { "summary" => finding.to_s }
          end
        }.compact
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
          worker_command_args: [],
          decomposition_command_runner: nil
        }

        parser = OptionParser.new
        parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
        parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
        parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
        parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
        add_kanban_bridge_options(parser, options)
        add_verification_command_runner_options(parser, options)
        add_decomposition_command_runner_options(parser, options)
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
          worker_command_args: [],
          decomposition_command_runner: nil
        }

        parser = OptionParser.new
        parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
        parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
        parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
        parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
        parser.on("--investigation-evidence-path PATH") { |value| options[:investigation_evidence_path] = File.expand_path(value) }
        add_kanban_bridge_options(parser, options)
        add_verification_command_runner_options(parser, options)
        add_decomposition_command_runner_options(parser, options)
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
          worker_command_args: [],
          decomposition_command_runner: nil
        }

        parser = OptionParser.new
        parser.on("--storage-backend BACKEND") { |value| options[:storage_backend] = value.to_sym }
        parser.on("--storage-dir DIR") { |value| options[:storage_dir] = File.expand_path(value) }
        parser.on("--repo-source SLOT=PATH") { |value| add_repo_source_option(options, value) }
        parser.on("--preset-dir DIR") { |value| options[:preset_dir] = File.expand_path(value) }
        parser.on("--proposal-evidence-path PATH") { |value| options[:proposal_evidence_path] = File.expand_path(value) }
        add_kanban_bridge_options(parser, options)
        add_verification_command_runner_options(parser, options)
        add_decomposition_command_runner_options(parser, options)
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
          parent_auto: true
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
        parser.on("--no-parent-auto") { options[:parent_auto] = false }
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
            if status.state == "none"
              status = A3::Application::ShowDecompositionStatus::Status.new(
                task_ref: task.ref,
                state: "queued",
                stage: nil,
                running: false,
                proposal_fingerprint: nil,
                disposition: nil,
                blocked_reason: nil,
                evidence_paths: {}
              )
            end
            active_stage = active_decomposition_stage_for(task: task, status: status)
            if active_stage
              status.stage = active_stage
              status.state = "active" if status.state == "queued"
              status.running = true
            end

            status
          end
        active_refs = entries.select { |entry| entry.respond_to?(:running) && entry.running }.map(&:task_ref)
        summary.tasks.each { |task| task.running = true if active_refs.include?(task.ref) && task.respond_to?(:running=) }
        summary.define_singleton_method(:decomposition_entries) { entries.freeze }
      end

      def active_decomposition_stage_for(task:, status:)
        return nil if %w[done blocked].include?(status.state)

        task_status = task.status.to_sym
        evidence_paths = status.evidence_paths || {}
        return "review" if task_status == :in_review

        if task_status == :in_progress
          return "create_children" if status.disposition == "eligible"
          return "review" if evidence_paths.key?("proposal")
          return "propose" if evidence_paths.key?("investigation")

          return "investigate"
        end

        nil
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

      def source_remote_for_task(task:, external_task_source:)
        return nil unless external_task_source

        packet =
          if task.external_task_id && external_task_source.respond_to?(:fetch_task_packet_by_external_task_id)
            external_task_source.fetch_task_packet_by_external_task_id(task.external_task_id)
          elsif external_task_source.respond_to?(:fetch_task_packet_by_ref)
            external_task_source.fetch_task_packet_by_ref(task.ref)
          end
        packet && packet["remote"]
      rescue A3::Domain::ConfigurationError, KeyError, RuntimeError
        nil
      end

      def add_decomposition_command_runner_options(parser, options)
        parser.on("--decomposition-command-runner VALUE") { |value| options[:decomposition_command_runner] = value }
        parser.on("--host-shared-root PATH") { |value| options[:host_shared_root] = File.expand_path(value) }
        parser.on("--container-shared-root PATH") { |value| options[:container_shared_root] = value }
        parser.on("--decomposition-workspace-dir PATH") { |value| options[:decomposition_workspace_dir] = File.expand_path(value) }
      end

      def build_decomposition_source_activity_publisher(options, fallback: nil)
        return build_kanban_cli_task_activity_publisher(options) if kanban_child_writer_configured?(options)

        fallback || A3::Infra::NullExternalTaskActivityPublisher.new
      end

      def build_decomposition_source_status_publisher(options, fallback: nil)
        return build_kanban_cli_task_status_publisher(options) if kanban_child_writer_configured?(options)

        fallback || A3::Infra::NullExternalTaskStatusPublisher.new
      end

      def build_decomposition_process_runner(options:, task_ref:, stage:, fallback: nil)
        runner = options[:decomposition_command_runner].to_s
        return fallback if runner.empty?
        return fallback if runner == "local"

        if runner == "agent-http"
          raise ArgumentError, "--agent-control-plane-url is required for --decomposition-command-runner agent-http" unless options[:agent_control_plane_url]
          validate_agent_control_plane_url!(options.fetch(:agent_control_plane_url), allow_insecure_remote: options.fetch(:agent_allow_insecure_remote, false))

          return A3::Infra::AgentDecompositionCommandRunner.new(
            control_plane_client: A3::Infra::AgentControlPlaneClient.new(
              base_url: options.fetch(:agent_control_plane_url),
              auth_token: agent_control_auth_token(options)
            ),
            runtime_profile: options.fetch(:agent_runtime_profile, "default"),
            task_ref: task_ref,
            stage: stage,
            project_key: options[:project_key],
            timeout_seconds: options.fetch(:agent_job_timeout_seconds, 1800),
            poll_interval_seconds: options.fetch(:agent_job_poll_interval_seconds, 1.0),
            env: options.fetch(:agent_env, {}),
            agent_environment: agent_environment_from_options(options)
          )
        end

        raise ArgumentError, "Unsupported decomposition command runner: #{runner}"
      end

      def enter_accept_drafts_scheduler_guard(scheduler_state_repository)
        state = scheduler_state_repository.fetch
        return { status: "already_paused", paused_by_guard: false, resumed: false } if state.paused

        A3::Application::PauseScheduler.new(scheduler_state_repository: scheduler_state_repository).call
        { status: "paused_for_accept_drafts", paused_by_guard: true, resumed: false }
      end

      def resume_accept_drafts_scheduler_guard(scheduler_state_repository, scheduler_guard)
        return scheduler_guard unless scheduler_guard.fetch(:paused_by_guard)

        A3::Application::ResumeScheduler.new(scheduler_state_repository: scheduler_state_repository).call
        scheduler_guard.merge(resumed: true)
      end

      def kanban_child_writer_configured?(options)
        options[:kanban_command] && options[:kanban_project]
      end

    end
  end
end
