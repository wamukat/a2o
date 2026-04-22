# frozen_string_literal: true

require "pathname"

module A3
  module Domain
    class RuntimePackageDescriptor
      KNOWN_REPO_SOURCE_STRATEGIES = %i[explicit_map none].freeze
      KNOWN_SECRET_DELIVERY_MODES = %i[environment_variable file_mount].freeze
      KNOWN_SCHEDULER_STORE_MIGRATION_STATES = %i[not_required applied pending].freeze

      attr_reader :image_version, :manifest_path, :project_runtime_root, :preset_dir,
                  :storage_backend, :state_root, :workspace_root, :artifact_root,
                  :repo_source_strategy, :repo_source_slots, :repo_sources,
                  :agent_runtime_profile, :agent_control_plane_url, :agent_profile_path,
                  :agent_source_aliases, :agent_workspace_freshness_policy, :agent_workspace_cleanup_policy,
                  :distribution_image_ref, :runtime_entrypoint, :doctor_entrypoint, :migration_entrypoint,
                  :secret_delivery_mode, :secret_reference, :scheduler_store_migration_state,
                  :manifest_schema_version, :required_manifest_schema_version,
                  :preset_chain, :preset_schema_versions, :required_preset_schema_version

      def initialize(image_version:, manifest_path:, project_runtime_root:, preset_dir:, storage_backend:, state_root:, workspace_root:, artifact_root:, repo_source_strategy:, repo_source_slots:, repo_sources:, distribution_image_ref:, runtime_entrypoint:, doctor_entrypoint:, migration_entrypoint:, secret_delivery_mode:, secret_reference:, scheduler_store_migration_state:, manifest_schema_version:, required_manifest_schema_version:, preset_chain:, preset_schema_versions:, required_preset_schema_version:, agent_runtime_profile: "host-local", agent_control_plane_url: "http://127.0.0.1:7393", agent_profile_path: "<agent-runtime-profile.json>", agent_source_aliases: nil, agent_workspace_freshness_policy: :reuse_if_clean_and_ref_matches, agent_workspace_cleanup_policy: :retain_until_a3_cleanup)
        @image_version = image_version.to_s
        @manifest_path = Pathname(manifest_path)
        @project_runtime_root = Pathname(project_runtime_root)
        @preset_dir = Pathname(preset_dir)
        @storage_backend = storage_backend.to_sym
        @state_root = Pathname(state_root)
        @workspace_root = Pathname(workspace_root)
        @artifact_root = Pathname(artifact_root)
        @repo_source_strategy = repo_source_strategy.to_sym
        @repo_source_slots = Array(repo_source_slots).map(&:to_sym).sort.freeze
        @repo_sources = repo_sources.transform_keys(&:to_sym).transform_values { |value| Pathname(value) }.freeze
        @agent_runtime_profile = agent_runtime_profile.to_s
        @agent_control_plane_url = agent_control_plane_url.to_s
        @agent_profile_path = agent_profile_path.to_s
        agent_source_aliases ||= @repo_source_slots.each_with_object({}) { |slot, aliases| aliases[slot] = slot.to_s }
        @agent_source_aliases = agent_source_aliases.transform_keys(&:to_sym).transform_values(&:to_s).freeze
        @agent_workspace_freshness_policy = agent_workspace_freshness_policy.to_sym
        @agent_workspace_cleanup_policy = agent_workspace_cleanup_policy.to_sym
        @distribution_image_ref = distribution_image_ref.to_s
        @runtime_entrypoint = runtime_entrypoint.to_s
        @doctor_entrypoint = doctor_entrypoint.to_s
        @migration_entrypoint = migration_entrypoint.to_s
        @secret_delivery_mode = secret_delivery_mode.to_sym
        @secret_reference = secret_reference.to_s
        @scheduler_store_migration_state = scheduler_store_migration_state.to_sym
        @manifest_schema_version = manifest_schema_version.to_s
        @required_manifest_schema_version = required_manifest_schema_version.to_s
        @preset_chain = Array(preset_chain).map(&:to_s).freeze
        @preset_schema_versions = preset_schema_versions.transform_keys(&:to_s).transform_values(&:to_s).freeze
        @required_preset_schema_version = required_preset_schema_version.to_s
        validate!
        freeze
      end

      def self.build(image_version:, manifest_path:, preset_dir:, storage_backend:, storage_dir:, repo_sources:, manifest_schema_version:, required_manifest_schema_version:, preset_chain:, preset_schema_versions:, required_preset_schema_version:, distribution_image_ref: nil, runtime_entrypoint: nil, doctor_entrypoint: nil, migration_entrypoint: nil, secret_delivery_mode: :environment_variable, secret_reference:, scheduler_store_migration_state: :not_required, agent_runtime_profile: "host-local", agent_control_plane_url: "http://127.0.0.1:7393", agent_profile_path: "<agent-runtime-profile.json>", agent_source_aliases: nil, agent_workspace_freshness_policy: :reuse_if_clean_and_ref_matches, agent_workspace_cleanup_policy: :retain_until_a3_cleanup)
        state_root = Pathname(storage_dir)
        distribution_image_ref ||= "a3-engine:#{image_version}"
        runtime_entrypoint ||= "bin/a3"
        doctor_entrypoint ||= "bin/a3 doctor-runtime"
        migration_entrypoint ||= "bin/a3 migrate-scheduler-store"
        agent_source_aliases ||= repo_sources.keys.each_with_object({}) { |slot, aliases| aliases[slot] = slot.to_s }
        secret_delivery_mode = secret_delivery_mode.to_sym
        new(
          image_version: image_version,
          manifest_path: manifest_path,
          project_runtime_root: Pathname(manifest_path).dirname,
          preset_dir: preset_dir,
          storage_backend: storage_backend,
          state_root: state_root,
          workspace_root: state_root.join("workspaces"),
          artifact_root: state_root.join("artifacts"),
          repo_source_strategy: repo_sources.empty? ? :none : :explicit_map,
          repo_source_slots: repo_sources.keys,
          repo_sources: repo_sources,
          agent_runtime_profile: agent_runtime_profile,
          agent_control_plane_url: agent_control_plane_url,
          agent_profile_path: agent_profile_path,
          agent_source_aliases: agent_source_aliases,
          agent_workspace_freshness_policy: agent_workspace_freshness_policy,
          agent_workspace_cleanup_policy: agent_workspace_cleanup_policy,
          distribution_image_ref: distribution_image_ref,
          runtime_entrypoint: runtime_entrypoint,
          doctor_entrypoint: doctor_entrypoint,
          migration_entrypoint: migration_entrypoint,
          secret_delivery_mode: secret_delivery_mode,
          secret_reference: secret_reference,
          scheduler_store_migration_state: scheduler_store_migration_state,
          manifest_schema_version: manifest_schema_version,
          required_manifest_schema_version: required_manifest_schema_version,
          preset_chain: preset_chain,
          preset_schema_versions: preset_schema_versions,
          required_preset_schema_version: required_preset_schema_version
        )
      end

      def storage_dir
        state_root
      end

      def writable_roots
        [state_root, workspace_root, artifact_root].freeze
      end

      def mount_summary
        {
          "state_root" => state_root,
          "logs_root" => state_root.join("logs"),
          "workspace_root" => workspace_root,
          "artifact_root" => artifact_root,
          "migration_marker_path" => migration_marker_path
        }.freeze
      end

      def repo_source_summary
        {
          "strategy" => repo_source_strategy,
          "slots" => repo_source_slots,
          "sources" => repo_sources.transform_values(&:to_s)
        }.freeze
      end

      def agent_runtime_profile_summary
        {
          "profile" => agent_runtime_profile,
          "control_plane_url" => agent_control_plane_url,
          "profile_path" => agent_profile_path,
          "source_aliases" => agent_source_aliases.transform_keys(&:to_s),
          "freshness_policy" => agent_workspace_freshness_policy,
          "cleanup_policy" => agent_workspace_cleanup_policy,
          "agent_command" => agent_runtime_command_summary,
          "worker_gateway_options" => agent_worker_gateway_options_summary
        }.freeze
      end

      def distribution_summary
        {
          "image_ref" => distribution_image_ref,
          "runtime_entrypoint" => runtime_entrypoint,
          "doctor_entrypoint" => doctor_entrypoint,
          "migration_entrypoint" => migration_entrypoint,
          "project_config_schema_version" => manifest_schema_version,
          "required_project_config_schema_version" => required_manifest_schema_version,
          "preset_chain" => preset_chain,
          "preset_schema_versions" => preset_schema_versions,
          "required_preset_schema_version" => required_preset_schema_version,
          "secret_delivery_mode" => secret_delivery_mode,
          "secret_reference" => secret_reference,
          "migration_marker_path" => migration_marker_path,
          "schema_contract" => schema_contract_summary,
          "preset_schema_contract" => preset_schema_contract_summary,
          "scheduler_store_migration_state" => scheduler_store_migration_state,
          "secret_contract" => secret_contract_summary,
          "migration_contract" => migration_contract_summary,
          "persistent_state_model" => persistent_state_model_summary,
          "retention_policy" => retention_policy_summary,
          "materialization_model" => materialization_model_summary,
          "runtime_configuration_model" => runtime_configuration_model_summary,
          "repository_metadata_model" => repository_metadata_model_summary,
          "branch_resolution_model" => branch_resolution_model_summary,
          "credential_boundary_model" => credential_boundary_model_summary,
          "observability_boundary_model" => observability_boundary_model_summary,
          "deployment_shape" => deployment_shape_summary,
          "networking_boundary" => networking_boundary_summary,
          "upgrade_contract" => upgrade_contract_summary,
          "fail_fast_policy" => fail_fast_policy_summary
        }.freeze
      end

      def operator_summary
        {
          "mount" => mount_summary.map { |key, value| "#{key}=#{value}" }.join(" "),
          "writable_roots" => writable_roots.map(&:to_s).join(","),
          "repo_sources" => [
            "strategy=#{repo_source_summary.fetch('strategy')}",
            "slots=#{repo_source_summary.fetch('slots').join(',')}",
            "paths=#{repo_source_summary.fetch('sources').map { |slot, path| "#{slot}=#{path}" }.join(',')}"
          ].join(" "),
          "distribution" => [
            "image_ref=#{distribution_summary.fetch('image_ref')}",
            "runtime_entrypoint=#{distribution_summary.fetch('runtime_entrypoint')}",
            "doctor_entrypoint=#{distribution_summary.fetch('doctor_entrypoint')}"
          ].join(" "),
          "schema_contract" => schema_contract_summary,
          "preset_schema_contract" => preset_schema_contract_summary,
          "repo_source_contract" => repo_source_contract_summary,
          "secret_contract" => secret_contract_summary,
          "migration_contract" => migration_contract_summary,
          "persistent_state_model" => persistent_state_model_summary,
          "retention_policy" => retention_policy_summary,
          "materialization_model" => materialization_model_summary,
          "runtime_configuration_model" => runtime_configuration_model_summary,
          "repository_metadata_model" => repository_metadata_model_summary,
          "branch_resolution_model" => branch_resolution_model_summary,
          "agent_runtime_profile" => agent_runtime_profile_contract_summary,
          "agent_runtime_command" => agent_runtime_command_summary,
          "agent_worker_gateway_options" => agent_worker_gateway_options_summary,
          "credential_boundary_model" => credential_boundary_model_summary,
          "observability_boundary_model" => observability_boundary_model_summary,
          "deployment_shape" => deployment_shape_summary,
          "networking_boundary" => networking_boundary_summary,
          "upgrade_contract" => upgrade_contract_summary,
          "fail_fast_policy" => fail_fast_policy_summary,
          "execution_modes" => execution_modes_summary,
          "execution_mode_contract" => execution_mode_contract_summary,
          "doctor_command" => doctor_command_summary,
          "migration_command" => migration_command_summary,
          "runtime_command" => runtime_command_summary,
          "runtime_validation_command" => runtime_validation_command_summary,
          "runtime_contract" => [schema_contract_summary, preset_schema_contract_summary, repo_source_contract_summary, secret_contract_summary, migration_contract_summary].join(" "),
          "schema_action" => schema_action_summary,
          "preset_schema_action" => preset_schema_action_summary,
          "repo_source_action" => repo_source_action_summary,
          "secret_delivery_action" => secret_delivery_action_summary,
          "scheduler_store_migration_action" => scheduler_store_migration_action_summary,
          "startup_checklist" => startup_checklist_summary,
          "descriptor_startup_readiness" => startup_readiness_summary,
          "startup_sequence" => startup_sequence_summary,
          "operator_action" => startup_checklist_summary
        }.freeze
      end

      def repo_source_contract_summary
        [
          "repo_source_strategy=#{repo_source_strategy}",
          "repo_source_slots=#{repo_source_slots.join(',')}"
        ].join(" ")
      end

      def agent_runtime_profile_contract_summary
        [
          "profile=#{agent_runtime_profile}",
          "control_plane_url=#{agent_control_plane_url}",
          "profile_path=#{agent_profile_path}",
          "source_aliases=#{agent_source_aliases.map { |slot, source_alias| "#{slot}=#{source_alias}" }.join(',')}",
          "freshness_policy=#{agent_workspace_freshness_policy}",
          "cleanup_policy=#{agent_workspace_cleanup_policy}"
        ].join(" ")
      end

      def agent_runtime_command_summary
        "a3-agent -config #{agent_profile_path}"
      end

      def agent_worker_gateway_options_summary
        alias_args = agent_source_aliases.sort_by { |slot, _| slot.to_s }.map do |slot, source_alias|
          "--agent-source-alias #{slot}=#{source_alias}"
        end
        ([
          "--worker-gateway agent-http",
          "--agent-control-plane-url #{agent_control_plane_url}",
          "--agent-runtime-profile #{agent_runtime_profile}",
          "--agent-shared-workspace-mode agent-materialized"
        ] + alias_args + [
          "--agent-workspace-freshness-policy #{agent_workspace_freshness_policy}",
          "--agent-workspace-cleanup-policy #{agent_workspace_cleanup_policy}"
        ]).join(" ")
      end

      def schema_contract_summary
        "project_config_schema_version=#{manifest_schema_version} required_project_config_schema_version=#{required_manifest_schema_version}"
      end

      def schema_action_summary
        "update project.yaml schema to #{required_manifest_schema_version}"
      end

      def preset_schema_contract_summary
        versions = preset_chain.map { |preset| "#{preset}:#{preset_schema_versions.fetch(preset, 'missing')}" }
        "required_preset_schema_version=#{required_preset_schema_version} preset_schema_versions=#{versions.join(',')}"
      end

      def preset_schema_action_summary
        mismatched = preset_chain.select { |preset| preset_schema_versions.fetch(preset) != required_preset_schema_version }
        return "no preset schema action required" if mismatched.empty?

        "update preset schema to #{required_preset_schema_version} for #{mismatched.join(',')}"
      end

      def preset_schema_matches?
        preset_chain.all? { |preset| preset_schema_versions.fetch(preset) == required_preset_schema_version }
      end

      def repo_source_action_summary
        case repo_source_strategy
        when :none
          "no repo source action required"
        when :explicit_map
          "provide writable repo sources for #{repo_source_slots.join(',')}"
        else
          "resolve repo source strategy #{repo_source_strategy}"
        end
      end

      def secret_contract_summary
        "secret_delivery_mode=#{secret_delivery_mode} secret_reference=#{secret_reference}"
      end

      def migration_contract_summary
        "scheduler_store_migration_state=#{scheduler_store_migration_state}"
      end

      def persistent_state_model_summary
        [
          "scheduler_state_root=#{state_root.join('scheduler')}",
          "task_repository_root=#{state_root.join('tasks')}",
          "run_repository_root=#{state_root.join('runs')}",
          "evidence_root=#{state_root.join('evidence')}",
          "blocked_diagnosis_root=#{state_root.join('blocked_diagnoses')}",
          "artifact_owner_cache_root=#{state_root.join('artifact_owner_cache')}",
          "logs_root=#{state_root.join('logs')}",
          "workspace_root=#{workspace_root}",
          "artifact_root=#{artifact_root}"
        ].join(" ")
      end

      def deployment_shape_summary
        [
          "runtime_package=single_project",
          "writable_state=isolated",
          "scheduler_instance=single_project",
          "state_boundary=project",
          "secret_boundary=project"
        ].join(" ")
      end

      def retention_policy_summary
        [
          "terminal_workspace_cleanup=retention_policy_controlled",
          "blocked_evidence_retention=independent_from_scheduler_cleanup",
          "image_upgrade_cleanup_trigger=none"
        ].join(" ")
      end

      def materialization_model_summary
        [
          "repo_slot_namespace=task_workspace_fixed",
          "implementation_workspace=ticket_workspace",
          "review_workspace=runtime_workspace",
          "verification_workspace=runtime_workspace",
          "merge_workspace=runtime_workspace",
          "runtime_workspace_kind=logical_phase_workspace",
          "physical_workspace_layout=worker_gateway_mode_defined",
          "agent_materialized_runtime_workspace=per_run_materialized",
          "missing_repo_rescue=forbidden",
          "source_descriptor_alignment=required_before_phase_start"
        ].join(" ")
      end

      def runtime_configuration_model_summary
        [
          "project_config_path=required",
          "preset_dir=required",
          "storage_backend=required",
          "state_root=required",
          "workspace_root=required",
          "artifact_root=required",
          "repo_source_strategy=required",
          "repository_metadata=required",
          "authoritative_branch_resolution=required",
          "integration_target_resolution=required",
          "secret_reference=required"
        ].join(" ")
      end

      def repository_metadata_model_summary
        [
          "repository_metadata=runtime_package_scoped",
          "source_descriptor_ref_resolution=required",
          "review_target_resolution=evidence_driven"
        ].join(" ")
      end

      def branch_resolution_model_summary
        [
          "authoritative_branch_resolution=runtime_package_scoped",
          "integration_target_resolution=runtime_package_scoped",
          "branch_integration_inputs=required"
        ].join(" ")
      end

      def credential_boundary_model_summary
        [
          "secret_reference=runtime_package_scoped",
          "token_reference=runtime_package_scoped",
          "credential_persistence=forbidden_in_workspace",
          "secret_injection=external_only"
        ].join(" ")
      end

      def observability_boundary_model_summary
        [
          "operator_logs_root=#{state_root.join('logs')}",
          "blocked_diagnosis_root=#{state_root.join('blocked_diagnoses')}",
          "evidence_root=#{state_root.join('evidence')}",
          "validation_output=stdout_only",
          "workspace_debug_reference=path_only"
        ].join(" ")
      end

      def networking_boundary_summary
        [
          "outbound=git,issue_api,package_registry,llm_gateway,verification_service",
          "secret_source=secret_store",
          "token_scope=project"
        ].join(" ")
      end

      def upgrade_contract_summary
        [
          "image_upgrade=independent",
          "project_config_schema_version=#{required_manifest_schema_version}",
          "preset_schema_version=#{required_preset_schema_version}",
          "state_migration=explicit"
        ].join(" ")
      end

      def fail_fast_policy_summary
        [
          "project_config_schema_mismatch=fail_fast",
          "preset_schema_conflict=fail_fast",
          "writable_mount_missing=fail_fast",
          "secret_missing=fail_fast",
          "scheduler_store_migration_pending=fail_fast"
        ].join(" ")
      end

      def secret_delivery_action_summary
        secret_delivery_action
      end

      def scheduler_store_migration_action_summary
        scheduler_store_migration_action
      end

      def startup_checklist_summary
        operator_action_summary
      end

      def startup_readiness_summary
        return "operator_action_required" if manifest_schema_version != required_manifest_schema_version
        return "operator_action_required" unless preset_schema_matches?
        return "operator_action_required" if scheduler_store_migration_state == :pending

        "descriptor_ready"
      end

      def execution_modes_summary
        [
          "one_shot_cli=#{doctor_command_summary} | #{migration_command_summary} | #{runtime_command_summary}",
          "scheduler_loop=#{runtime_command_summary}",
          "doctor_inspect=#{doctor_command_summary}"
        ].join(" ; ")
      end

      def execution_mode_contract_summary
        [
          "one_shot_cli=operator_driven_doctor_migration_runtime",
          "scheduler_loop=continuous_runnable_processing_after_runtime_ready",
          "doctor_inspect=configuration_and_mount_validation_only"
        ].join(" ; ")
      end

      def doctor_command_summary
        "#{doctor_entrypoint} #{manifest_path} --preset-dir #{preset_dir} --storage-backend #{storage_backend} --storage-dir #{state_root}"
      end

      def migration_command_summary
        "#{migration_entrypoint} #{manifest_path} --preset-dir #{preset_dir} --storage-backend #{storage_backend} --storage-dir #{state_root}"
      end

      def migration_marker_path
        state_root.join(".a3", "scheduler-store-migration.applied")
      end

      def runtime_command_summary
        "#{runtime_entrypoint} execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend #{storage_backend} --storage-dir #{state_root}"
      end

      def runtime_validation_command_summary
        commands = [doctor_command_summary]
        commands << migration_command_summary if scheduler_store_migration_state == :pending
        commands << runtime_command_summary
        commands.join(" && ")
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.image_version == image_version &&
          other.manifest_path == manifest_path &&
          other.project_runtime_root == project_runtime_root &&
          other.preset_dir == preset_dir &&
          other.storage_backend == storage_backend &&
          other.state_root == state_root &&
          other.workspace_root == workspace_root &&
          other.artifact_root == artifact_root &&
          other.repo_source_strategy == repo_source_strategy &&
          other.repo_source_slots == repo_source_slots &&
          other.repo_sources == repo_sources &&
          other.agent_runtime_profile == agent_runtime_profile &&
          other.agent_control_plane_url == agent_control_plane_url &&
          other.agent_profile_path == agent_profile_path &&
          other.agent_source_aliases == agent_source_aliases &&
          other.agent_workspace_freshness_policy == agent_workspace_freshness_policy &&
          other.agent_workspace_cleanup_policy == agent_workspace_cleanup_policy &&
          other.distribution_image_ref == distribution_image_ref &&
          other.runtime_entrypoint == runtime_entrypoint &&
          other.doctor_entrypoint == doctor_entrypoint &&
          other.migration_entrypoint == migration_entrypoint &&
          other.secret_delivery_mode == secret_delivery_mode &&
          other.secret_reference == secret_reference &&
          other.scheduler_store_migration_state == scheduler_store_migration_state &&
          other.manifest_schema_version == manifest_schema_version &&
          other.required_manifest_schema_version == required_manifest_schema_version &&
          other.preset_chain == preset_chain &&
          other.preset_schema_versions == preset_schema_versions &&
          other.required_preset_schema_version == required_preset_schema_version
      end
      alias eql? ==

      private

      def operator_action_summary
        actions = []
        actions << schema_action_summary unless manifest_schema_version == required_manifest_schema_version
        actions << preset_schema_action_summary unless preset_schema_matches?
        actions << repo_source_action_summary unless repo_source_strategy == :none
        actions << secret_delivery_action
        actions << scheduler_store_migration_action
        actions.join("; ")
      end

      def secret_delivery_action
        case secret_delivery_mode
        when :environment_variable
          "provide secrets via environment variable #{secret_reference}"
        when :file_mount
          "provide secrets via mounted file #{secret_reference}"
        else
          "provide secrets via #{secret_delivery_mode} #{secret_reference}"
        end
      end

      def scheduler_store_migration_action
        case scheduler_store_migration_state
        when :not_required
          "scheduler store migration not required"
        when :applied
          "scheduler store migration already applied"
        when :pending
          "apply scheduler store migration before startup"
        else
          "scheduler store migration state is #{scheduler_store_migration_state}"
        end
      end

      def startup_sequence_summary
        migration_step = scheduler_store_migration_state == :pending ? migration_command_summary : "skip"
        "doctor=#{doctor_command_summary} migrate=#{migration_step} runtime=#{runtime_command_summary}"
      end

      def validate!
        raise ConfigurationError, "image_version must be provided" if image_version.empty?
        raise ConfigurationError, "manifest_path must be absolute" unless manifest_path.absolute?
        raise ConfigurationError, "project_runtime_root must be absolute" unless project_runtime_root.absolute?
        raise ConfigurationError, "preset_dir must be absolute" unless preset_dir.absolute?
        raise ConfigurationError, "state_root must be absolute" unless state_root.absolute?
        raise ConfigurationError, "workspace_root must be absolute" unless workspace_root.absolute?
        raise ConfigurationError, "artifact_root must be absolute" unless artifact_root.absolute?
        raise ConfigurationError, "agent_runtime_profile must be provided" if agent_runtime_profile.empty?
        raise ConfigurationError, "agent_control_plane_url must be provided" if agent_control_plane_url.empty?
        raise ConfigurationError, "agent_profile_path must be provided" if agent_profile_path.empty?
        raise ConfigurationError, "agent source aliases must cover repo source slots" unless agent_source_aliases.keys.sort == repo_source_slots.sort
        raise ConfigurationError, "agent source aliases must be provided" if agent_source_aliases.values.any?(&:empty?)
        raise ConfigurationError, "distribution_image_ref must be provided" if distribution_image_ref.empty?
        raise ConfigurationError, "runtime_entrypoint must be provided" if runtime_entrypoint.empty?
        raise ConfigurationError, "doctor_entrypoint must be provided" if doctor_entrypoint.empty?
        raise ConfigurationError, "migration_entrypoint must be provided" if migration_entrypoint.empty?
        raise ConfigurationError, "manifest_schema_version must be provided" if manifest_schema_version.empty?
        raise ConfigurationError, "required_manifest_schema_version must be provided" if required_manifest_schema_version.empty?
        raise ConfigurationError, "required_preset_schema_version must be provided" if required_preset_schema_version.empty?
        raise ConfigurationError, "secret_reference must be provided" if secret_reference.empty?
        unless preset_chain.sort == preset_schema_versions.keys.sort
          raise ConfigurationError, "preset_schema_versions must match preset_chain"
        end
        raise ConfigurationError, "preset schema versions must be provided" if preset_schema_versions.values.any?(&:empty?)
        unless KNOWN_SECRET_DELIVERY_MODES.include?(secret_delivery_mode)
          raise ConfigurationError, "unsupported secret_delivery_mode: #{secret_delivery_mode.inspect}"
        end
        unless KNOWN_SCHEDULER_STORE_MIGRATION_STATES.include?(scheduler_store_migration_state)
          raise ConfigurationError, "unsupported scheduler_store_migration_state: #{scheduler_store_migration_state.inspect}"
        end
        unless A3::Domain::AgentWorkspaceRequest::FRESHNESS_POLICIES.include?(agent_workspace_freshness_policy)
          raise ConfigurationError, "unsupported agent workspace freshness policy: #{agent_workspace_freshness_policy.inspect}"
        end
        unless A3::Domain::AgentWorkspaceRequest::CLEANUP_POLICIES.include?(agent_workspace_cleanup_policy)
          raise ConfigurationError, "unsupported agent workspace cleanup policy: #{agent_workspace_cleanup_policy.inspect}"
        end
        return if KNOWN_REPO_SOURCE_STRATEGIES.include?(repo_source_strategy)

        raise ConfigurationError, "unsupported repo_source_strategy: #{repo_source_strategy.inspect}"
      end

    end
  end
end
