# frozen_string_literal: true

module A3
  module CLI
    module ArtifactHandlers
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
    end
  end
end
