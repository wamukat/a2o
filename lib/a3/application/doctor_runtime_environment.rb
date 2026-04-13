# frozen_string_literal: true

module A3
  module Application
    class DoctorRuntimeEnvironment
      PathCheck = Struct.new(:name, :path, :status, :detail, keyword_init: true)
      Result = Struct.new(:status, :image_version, :storage_backend, :project_runtime_root, :repo_source_strategy, :repo_source_slots, :repo_source_paths, :writable_roots, :mount_summary, :repo_source_summary, :distribution_summary, :schema_contract_summary, :preset_schema_contract_summary, :repo_source_contract_summary, :secret_contract_summary, :migration_contract_summary, :schema_action_summary, :preset_schema_action_summary, :repo_source_action_summary, :secret_delivery_action_summary, :scheduler_store_migration_action_summary, :contract_health, :startup_readiness, :startup_blockers, :execution_modes_summary, :execution_mode_contract_summary, :recommended_execution_mode, :recommended_execution_mode_reason, :recommended_execution_mode_command, :doctor_command_summary, :migration_command_summary, :runtime_command_summary, :runtime_validation_command_summary, :next_command, :startup_sequence, :operator_guidance, :checks, keyword_init: true)

      def initialize(runtime_package:, migration_marker_store: A3::Infra::LocalMigrationMarkerStore.new)
        @runtime_package = runtime_package
        @migration_marker_store = migration_marker_store
      end

      def call
        descriptor = @runtime_package
        checks = [
          file_check(:manifest_path, descriptor.manifest_path),
          manifest_schema_check(descriptor),
          preset_schema_check(descriptor),
          directory_check(:preset_dir, descriptor.preset_dir),
          mounted_directory_check(:project_runtime_root, descriptor.project_runtime_root),
          writable_path_check(:state_root, descriptor.state_root),
          secret_delivery_check(descriptor),
          scheduler_store_migration_check(descriptor),
          *writable_root_checks(descriptor),
          *repo_source_checks(descriptor),
          agent_runtime_profile_check(descriptor),
          agent_source_alias_coverage_check(descriptor),
          agent_workspace_policy_check(descriptor)
        ].freeze

        Result.new(
          status: checks.all? { |check| check.status == :ok } ? :ok : :invalid_runtime,
          image_version: descriptor.image_version,
          storage_backend: descriptor.storage_backend,
          project_runtime_root: descriptor.project_runtime_root,
          repo_source_strategy: descriptor.repo_source_strategy,
          repo_source_slots: descriptor.repo_source_slots,
          repo_source_paths: descriptor.repo_sources.transform_values(&:to_s),
          writable_roots: descriptor.writable_roots,
          mount_summary: mount_summary(descriptor),
          repo_source_summary: repo_source_summary(descriptor),
          distribution_summary: descriptor.distribution_summary,
          schema_contract_summary: descriptor.schema_contract_summary,
          preset_schema_contract_summary: descriptor.preset_schema_contract_summary,
          repo_source_contract_summary: descriptor.repo_source_contract_summary,
          secret_contract_summary: descriptor.secret_contract_summary,
          migration_contract_summary: descriptor.migration_contract_summary,
          schema_action_summary: descriptor.schema_action_summary,
          preset_schema_action_summary: descriptor.preset_schema_action_summary,
          repo_source_action_summary: descriptor.repo_source_action_summary,
          secret_delivery_action_summary: descriptor.secret_delivery_action_summary,
          scheduler_store_migration_action_summary: descriptor.scheduler_store_migration_action_summary,
          contract_health: contract_health_summary(checks),
          startup_readiness: startup_readiness_summary(checks),
          startup_blockers: startup_blockers_summary(checks),
          execution_modes_summary: descriptor.execution_modes_summary,
          execution_mode_contract_summary: descriptor.execution_mode_contract_summary,
          recommended_execution_mode: recommended_execution_mode(checks),
          recommended_execution_mode_reason: recommended_execution_mode_reason(checks),
          recommended_execution_mode_command: recommended_execution_mode_command(descriptor, checks),
          doctor_command_summary: descriptor.doctor_command_summary,
          migration_command_summary: descriptor.migration_command_summary,
          runtime_command_summary: descriptor.runtime_command_summary,
          runtime_validation_command_summary: runtime_validation_command_summary(descriptor, checks),
          next_command: next_command_summary(descriptor, checks),
          startup_sequence: startup_sequence_summary(descriptor, checks),
          operator_guidance: operator_guidance(descriptor, checks),
          checks: checks
        )
      end

      private

      def file_check(name, path)
        path = Pathname(path)
        status = path.file? ? :ok : :missing
        detail = status == :ok ? 'file exists' : 'expected file is missing'
        PathCheck.new(name: name, path: path, status: status, detail: detail)
      end

      def repo_source_checks(descriptor)
        return [] unless descriptor.repo_source_strategy == :explicit_map

        descriptor.repo_sources.sort_by { |slot, _| slot.to_s }.map do |slot, path|
          path = Pathname(path)
          path.exist? ? writable_path_check("repo_source.#{slot}".to_sym, path) : directory_check("repo_source.#{slot}".to_sym, path)
        end
      end

      def agent_runtime_profile_check(descriptor)
        if descriptor.agent_runtime_profile.empty? || descriptor.agent_control_plane_url.empty?
          return PathCheck.new(name: :agent_runtime_profile, path: descriptor.agent_profile_path, status: :invalid, detail: "agent runtime profile and control plane url are required")
        end

        PathCheck.new(name: :agent_runtime_profile, path: descriptor.agent_profile_path, status: :ok, detail: "agent runtime profile contract is present")
      end

      def agent_source_alias_coverage_check(descriptor)
        missing_slots = descriptor.repo_source_slots.reject { |slot| descriptor.agent_source_aliases.key?(slot) && !descriptor.agent_source_aliases.fetch(slot).empty? }
        if missing_slots.empty?
          return PathCheck.new(name: :agent_source_aliases, path: descriptor.agent_profile_path, status: :ok, detail: "agent source aliases cover repo source slots")
        end

        PathCheck.new(name: :agent_source_aliases, path: descriptor.agent_profile_path, status: :invalid, detail: "missing agent source aliases for #{missing_slots.join(',')}")
      end

      def agent_workspace_policy_check(descriptor)
        freshness_ok = A3::Domain::AgentWorkspaceRequest::FRESHNESS_POLICIES.include?(descriptor.agent_workspace_freshness_policy)
        cleanup_ok = A3::Domain::AgentWorkspaceRequest::CLEANUP_POLICIES.include?(descriptor.agent_workspace_cleanup_policy)
        if freshness_ok && cleanup_ok
          return PathCheck.new(name: :agent_workspace_policy, path: descriptor.agent_profile_path, status: :ok, detail: "agent workspace policies are supported")
        end

        PathCheck.new(name: :agent_workspace_policy, path: descriptor.agent_profile_path, status: :invalid, detail: "unsupported agent workspace policy")
      end

      def writable_root_checks(descriptor)
        {
          writable_root_state_root: descriptor.state_root,
          writable_root_workspace_root: descriptor.workspace_root,
          writable_root_artifact_root: descriptor.artifact_root
        }.map do |name, path|
          writable_path_check(name, path)
        end
      end

      def directory_check(name, path)
        path = Pathname(path)
        status = path.directory? ? :ok : :missing
        detail = status == :ok ? 'directory exists' : 'expected directory is missing'
        PathCheck.new(name: name, path: path, status: status, detail: detail)
      end

      def mounted_directory_check(name, path)
        path = Pathname(path)
        if path.directory?
          PathCheck.new(name: name, path: path, status: :ok, detail: 'directory exists')
        elsif path.exist?
          PathCheck.new(name: name, path: path, status: :invalid, detail: 'expected mounted directory but found a file')
        else
          PathCheck.new(name: name, path: path, status: :missing, detail: 'expected mounted directory is missing')
        end
      end

      def mount_summary(descriptor)
        {
          "state_root" => descriptor.state_root,
          "logs_root" => descriptor.state_root.join("logs"),
          "workspace_root" => descriptor.workspace_root,
          "artifact_root" => descriptor.artifact_root,
          "migration_marker_path" => descriptor.migration_marker_path
        }.freeze
      end

      def repo_source_summary(descriptor)
        {
          "strategy" => descriptor.repo_source_strategy,
          "slots" => descriptor.repo_source_slots,
          "sources" => descriptor.repo_sources.transform_values(&:to_s)
        }.freeze
      end

      def scheduler_store_migration_check(descriptor)
        state = descriptor.scheduler_store_migration_state
        case state
        when :applied, :not_required
          PathCheck.new(name: :scheduler_store_migration, path: descriptor.state_root, status: :ok, detail: "scheduler store migration #{state}")
        when :pending
          if @migration_marker_store.applied?(descriptor)
            PathCheck.new(name: :scheduler_store_migration, path: descriptor.migration_marker_path, status: :ok, detail: "scheduler store migration marker is present")
          else
            PathCheck.new(name: :scheduler_store_migration, path: descriptor.migration_marker_path, status: :pending, detail: "scheduler store migration is pending")
          end
        else
          PathCheck.new(name: :scheduler_store_migration, path: descriptor.state_root, status: :invalid, detail: "unsupported scheduler store migration state: #{state.inspect}")
        end
      end

      def manifest_schema_check(descriptor)
        if descriptor.manifest_schema_version == descriptor.required_manifest_schema_version
          PathCheck.new(name: :manifest_schema, path: descriptor.manifest_path, status: :ok, detail: "manifest schema #{descriptor.manifest_schema_version} matches runtime requirement")
        else
          PathCheck.new(name: :manifest_schema, path: descriptor.manifest_path, status: :invalid, detail: "manifest schema #{descriptor.manifest_schema_version} does not match required #{descriptor.required_manifest_schema_version}")
        end
      end

      def preset_schema_check(descriptor)
        return PathCheck.new(name: :preset_schema, path: descriptor.preset_dir, status: :ok, detail: "preset schema matches runtime requirement") if descriptor.preset_schema_matches?

        detail = descriptor.preset_chain.map { |preset| "#{preset}=#{descriptor.preset_schema_versions.fetch(preset)}" }.join(",")
        PathCheck.new(name: :preset_schema, path: descriptor.preset_dir, status: :invalid, detail: "preset schema does not match required #{descriptor.required_preset_schema_version}: #{detail}")
      end

      def contract_health_summary(checks)
        schema_status = checks.find { |check| check.name == :manifest_schema }&.status || :unknown
        preset_schema_status = checks.find { |check| check.name == :preset_schema }&.status || :unknown
        repo_source_status = repo_source_health(checks)
        secret_status = checks.find { |check| check.name == :secret_delivery }&.status || :unknown
        migration_status = checks.find { |check| check.name == :scheduler_store_migration }&.status || :unknown
        "manifest_schema=#{schema_status} preset_schema=#{preset_schema_status} repo_sources=#{repo_source_status} secret_delivery=#{secret_status} scheduler_store_migration=#{migration_status}"
      end

      def operator_guidance(descriptor, checks)
        actions = []
        schema_check = checks.find { |check| check.name == :manifest_schema }
        preset_schema_check = checks.find { |check| check.name == :preset_schema }
        repo_source_status = repo_source_health(checks)
        agent_runtime_status = agent_runtime_health(checks)
        secret_check = checks.find { |check| check.name == :secret_delivery }
        migration_check = checks.find { |check| check.name == :scheduler_store_migration }
        actions << descriptor.schema_action_summary unless schema_check&.status == :ok
        actions << descriptor.preset_schema_action_summary unless preset_schema_check&.status == :ok
        actions << descriptor.repo_source_action_summary unless repo_source_status == :ok
        actions << "fix agent runtime profile contract" unless agent_runtime_status == :ok
        actions << descriptor.secret_delivery_action_summary unless secret_check&.status == :ok
        actions << descriptor.scheduler_store_migration_action_summary unless migration_check&.status == :ok
        return "startup ready; runtime package contract satisfied; run #{descriptor.runtime_command_summary}" if actions.empty?

        "startup blocked by #{startup_blockers_summary(checks)}; #{actions.join('; ')}; run #{descriptor.doctor_command_summary}"
      end

      def next_command_summary(descriptor, checks)
        readiness = startup_readiness_summary(checks)
        return descriptor.runtime_command_summary if readiness == :ready
        return descriptor.migration_command_summary if migration_next?(checks)

        descriptor.doctor_command_summary
      end

      def runtime_validation_command_summary(descriptor, checks)
        commands = [descriptor.doctor_command_summary]
        if startup_readiness_summary(checks) == :ready
          commands << descriptor.runtime_command_summary
        elsif migration_next?(checks)
          commands << descriptor.migration_command_summary
          commands << descriptor.runtime_command_summary
        end
        commands.join(" && ")
      end

      def startup_sequence_summary(descriptor, checks)
        if startup_readiness_summary(checks) == :ready
          "doctor=#{descriptor.doctor_command_summary} migrate=skip runtime=#{descriptor.runtime_command_summary}"
        elsif migration_next?(checks)
          "doctor=#{descriptor.doctor_command_summary} migrate=#{descriptor.migration_command_summary} runtime=#{descriptor.runtime_command_summary}"
        else
          "doctor=#{descriptor.doctor_command_summary} migrate=blocked runtime=blocked"
        end
      end

      def startup_readiness_summary(checks)
        blocking_statuses = checks.select { |check| check.status != :ok }.map(&:status)
        return :ready if blocking_statuses.empty?
        return :blocked if blocking_statuses.include?(:pending)

        :invalid
      end

      def recommended_execution_mode(checks)
        return :one_shot_cli if startup_readiness_summary(checks) == :ready
        return :one_shot_cli if migration_next?(checks)

        :doctor_inspect
      end

      def recommended_execution_mode_reason(checks)
        if startup_readiness_summary(checks) == :ready
          "runtime contract satisfied; use one_shot_cli to validate execution or start scheduler processing"
        elsif migration_next?(checks)
          "scheduler store migration is the only startup blocker; use one_shot_cli to apply migration and continue startup"
        else
          "runtime is not ready; use doctor_inspect until blockers are resolved"
        end
      end

      def recommended_execution_mode_command(descriptor, checks)
        case recommended_execution_mode(checks)
        when :one_shot_cli
          runtime_validation_command_summary(descriptor, checks)
        when :doctor_inspect
          descriptor.doctor_command_summary
        else
          raise A3::Domain::ConfigurationError, "unsupported recommended execution mode: #{recommended_execution_mode(checks).inspect}"
        end
      end

      def startup_blockers_summary(checks)
        blockers = []
        blockers << :manifest_schema if checks.any? { |check| check.name == :manifest_schema && check.status != :ok }
        blockers << :preset_schema if checks.any? { |check| check.name == :preset_schema && check.status != :ok }
        blockers << :runtime_paths if checks.any? { |check| runtime_path_check?(check) && check.status != :ok }
        blockers << :repo_sources unless repo_source_health(checks) == :ok
        blockers << :agent_runtime unless agent_runtime_health(checks) == :ok
        blockers << :secret_delivery if checks.any? { |check| check.name == :secret_delivery && check.status != :ok }
        blockers << :scheduler_store_migration if checks.any? { |check| check.name == :scheduler_store_migration && check.status != :ok }
        return "none" if blockers.empty?

        blockers.join(",")
      end

      def repo_source_health(checks)
        repo_checks = checks.select { |check| check.name.to_s.start_with?("repo_source.") }
        return :ok if repo_checks.empty?

        non_ok = repo_checks.map(&:status).reject { |status| status == :ok }
        return :ok if non_ok.empty?
        return :not_writable if non_ok.include?(:not_writable)
        return :missing if non_ok.include?(:missing)

        non_ok.first
      end

      def agent_runtime_health(checks)
        agent_checks = checks.select { |check| %i[agent_runtime_profile agent_source_aliases agent_workspace_policy].include?(check.name) }
        return :ok if agent_checks.empty?

        non_ok = agent_checks.map(&:status).reject { |status| status == :ok }
        non_ok.empty? ? :ok : non_ok.first
      end

      def runtime_path_check?(check)
        check.name == :manifest_path ||
          check.name == :preset_dir ||
          check.name == :project_runtime_root ||
          check.name == :state_root ||
          check.name.to_s.start_with?("writable_root_")
      end

      def migration_pending?(checks)
        checks.any? { |check| check.name == :scheduler_store_migration && check.status == :pending }
      end

      def migration_next?(checks)
        migration_pending?(checks) && startup_blockers_summary(checks) == "scheduler_store_migration"
      end

      def secret_delivery_check(descriptor)
        case descriptor.secret_delivery_mode
        when :environment_variable
          value = ENV[descriptor.secret_reference]
          status = value.to_s.empty? ? :missing : :ok
          detail = status == :ok ? "environment variable #{descriptor.secret_reference} is present" : "environment variable #{descriptor.secret_reference} is missing"
          PathCheck.new(name: :secret_delivery, path: descriptor.secret_reference, status: status, detail: detail)
        when :file_mount
          path = Pathname(descriptor.secret_reference)
          if path.file? && path.readable?
            PathCheck.new(name: :secret_delivery, path: path, status: :ok, detail: "secret file #{path} is readable")
          elsif path.exist?
            PathCheck.new(name: :secret_delivery, path: path, status: :invalid, detail: "secret reference exists but is not a readable file")
          else
            PathCheck.new(name: :secret_delivery, path: path, status: :missing, detail: "secret file #{path} is missing")
          end
        else
          PathCheck.new(name: :secret_delivery, path: descriptor.secret_reference, status: :invalid, detail: "unsupported secret delivery mode: #{descriptor.secret_delivery_mode.inspect}")
        end
      end

      def writable_path_check(name, path)
        path = Pathname(path)
        if path.exist?
          return PathCheck.new(name: name, path: path, status: :ok, detail: 'directory exists and is writable') if path.directory? && path.writable?
          return PathCheck.new(name: name, path: path, status: :not_writable, detail: 'directory exists but is not writable') if path.directory?

          return PathCheck.new(name: name, path: path, status: :invalid, detail: 'expected writable directory but found a file')
        end

        parent = nearest_existing_parent(path)
        if parent&.directory? && parent.writable?
          PathCheck.new(name: name, path: path, status: :ok, detail: 'directory does not exist yet but can be created')
        else
          PathCheck.new(name: name, path: path, status: :not_writable, detail: 'directory cannot be created from the current runtime roots')
        end
      end

      def nearest_existing_parent(path)
        current = path.parent
        until current == current.parent
          return current if current.exist?

          current = current.parent
        end
        current if current.exist?
      end
    end
  end
end
