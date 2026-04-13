# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::DoctorRuntimeEnvironment do
  def with_env(values)
    original = {}
    values.each do |key, value|
      original[key] = ENV.key?(key) ? ENV[key] : :__missing__
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    original.each do |key, value|
      value == :__missing__ ? ENV.delete(key) : ENV[key] = value
    end
  end

  it "reports ok when manifest, preset dir, and state root exist" do
    with_env("A3_SECRET" => "token") do
      Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "presets: []
")
      runtime_package = A3::Domain::RuntimePackageDescriptor.build(
        image_version: "a3:v2.1.0",
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: {},
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1",
        secret_reference: "A3_SECRET"
      )

      result = described_class.new(runtime_package: runtime_package).call

      expect(result.status).to eq(:ok)
      expect(result.repo_source_strategy).to eq(:none)
      expect(result.repo_source_paths).to eq({})
      expect(result.project_runtime_root.to_s).to eq(dir)
      expect(result.writable_roots.map(&:to_s)).to include(dir, File.join(dir, "workspaces"), File.join(dir, "artifacts"))
      expect(result.mount_summary.fetch("state_root").to_s).to eq(dir)
      expect(result.mount_summary.fetch("logs_root").to_s).to eq(File.join(dir, "logs"))
      expect(result.repo_source_summary.fetch("strategy")).to eq(:none)
      expect(result.repo_source_contract_summary).to eq("repo_source_strategy=none repo_source_slots=")
      expect(result.distribution_summary).to eq(
        "image_ref" => "a3-engine:a3:v2.1.0",
        "runtime_entrypoint" => "bin/a3",
        "doctor_entrypoint" => "bin/a3 doctor-runtime",
        "migration_entrypoint" => "bin/a3 migrate-scheduler-store",
        "manifest_schema_version" => "1",
        "required_manifest_schema_version" => "1",
        "preset_chain" => [],
        "preset_schema_versions" => {},
        "required_preset_schema_version" => "1",
        "schema_contract" => "manifest_schema_version=1 required_manifest_schema_version=1",
        "preset_schema_contract" => "required_preset_schema_version=1 preset_schema_versions=",
        "secret_delivery_mode" => :environment_variable,
        "secret_reference" => "A3_SECRET",
        "migration_marker_path" => runtime_package.migration_marker_path,
        "secret_contract" => "secret_delivery_mode=environment_variable secret_reference=A3_SECRET",
        "scheduler_store_migration_state" => :not_required,
        "migration_contract" => "scheduler_store_migration_state=not_required",
        "persistent_state_model" => "scheduler_state_root=#{Pathname(dir).join('scheduler')} task_repository_root=#{Pathname(dir).join('tasks')} run_repository_root=#{Pathname(dir).join('runs')} evidence_root=#{Pathname(dir).join('evidence')} blocked_diagnosis_root=#{Pathname(dir).join('blocked_diagnoses')} artifact_owner_cache_root=#{Pathname(dir).join('artifact_owner_cache')} logs_root=#{Pathname(dir).join('logs')} workspace_root=#{Pathname(dir).join('workspaces')} artifact_root=#{Pathname(dir).join('artifacts')}",
        "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
        "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
        "runtime_configuration_model" => "manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
        "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
        "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
        "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        "observability_boundary_model" => "operator_logs_root=#{Pathname(dir).join('logs')} blocked_diagnosis_root=#{Pathname(dir).join('blocked_diagnoses')} evidence_root=#{Pathname(dir).join('evidence')} validation_output=stdout_only workspace_debug_reference=path_only",
        "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
        "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
        "upgrade_contract" => "image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit",
        "fail_fast_policy" => "manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast"
      )
      expect(result.schema_contract_summary).to eq("manifest_schema_version=1 required_manifest_schema_version=1")
      expect(result.preset_schema_contract_summary).to eq("required_preset_schema_version=1 preset_schema_versions=")
      expect(result.secret_contract_summary).to eq("secret_delivery_mode=environment_variable secret_reference=A3_SECRET")
      expect(result.migration_contract_summary).to eq("scheduler_store_migration_state=not_required")
      expect(result.contract_health).to eq("manifest_schema=ok preset_schema=ok repo_sources=ok secret_delivery=ok scheduler_store_migration=ok")
      expect(result.startup_readiness).to eq(:ready)
      expect(result.startup_blockers).to eq("none")
      expect(result.execution_modes_summary).to eq("one_shot_cli=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} | bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} | bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} ; scheduler_loop=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} ; doctor_inspect=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.execution_mode_contract_summary).to eq("one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only")
      expect(result.recommended_execution_mode).to eq(:one_shot_cli)
      expect(result.recommended_execution_mode_reason).to eq("runtime contract satisfied; use one_shot_cli to validate execution or start scheduler processing")
      expect(result.recommended_execution_mode_command).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.doctor_command_summary).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.migration_command_summary).to eq("bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.runtime_command_summary).to eq("bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.runtime_validation_command_summary).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.next_command).to eq("bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.startup_sequence).to eq("doctor=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} migrate=skip runtime=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.operator_guidance).to eq("startup ready; runtime package contract satisfied; run bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.checks.map(&:status)).to all(eq(:ok))
      expect(result.checks.map(&:name)).to include(:preset_schema, :project_runtime_root, :secret_delivery, :scheduler_store_migration, :writable_root_state_root, :writable_root_workspace_root, :writable_root_artifact_root, :agent_runtime_profile, :agent_source_aliases, :agent_workspace_policy)
      end
    end
  end

  it "reports invalid_runtime when required runtime paths are missing" do
    runtime_package = A3::Domain::RuntimePackageDescriptor.build(
      image_version: "a3:v2.1.0",
      manifest_path: "/tmp/a3-v2-missing/manifest.yml",
      preset_dir: "/tmp/a3-v2-missing/presets",
      storage_backend: :json,
      storage_dir: "/tmp/a3-v2-missing/state",
      repo_sources: {},
      manifest_schema_version: "missing",
      required_manifest_schema_version: "1",
      preset_chain: [],
      preset_schema_versions: {},
      required_preset_schema_version: "1",
        secret_reference: "A3_SECRET"
    )

    result = described_class.new(runtime_package: runtime_package).call

    expect(result.status).to eq(:invalid_runtime)
    expect(result.repo_source_paths).to eq({})
    expect(result.writable_roots.map(&:to_s)).to include(File.join("/tmp/a3-v2-missing/state", "workspaces"), File.join("/tmp/a3-v2-missing/state", "artifacts"))
    expect(result.mount_summary.fetch("state_root").to_s).to eq("/tmp/a3-v2-missing/state")
    expect(result.repo_source_summary.fetch("strategy")).to eq(:none)
    expect(result.distribution_summary.fetch("image_ref")).to eq("a3-engine:a3:v2.1.0")
    manifest_schema_check = result.checks.find { |check| check.name == :manifest_schema }
    expect(manifest_schema_check).to have_attributes(status: :invalid)
    expect(result.checks.reject { |check| %i[manifest_schema preset_schema].include?(check.name) }.map(&:status)).to all(eq(:missing).or(eq(:ok)))
  end

  it "reports ok when state root does not exist yet but can be created" do
    with_env("A3_SECRET" => "token") do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "manifest.yml")
        preset_dir = File.join(dir, "presets")
        state_dir = File.join(dir, "state")
        FileUtils.mkdir_p(preset_dir)
        File.write(manifest_path, "presets: []\n")

        runtime_package = A3::Domain::RuntimePackageDescriptor.build(
          image_version: "a3:v2.1.0",
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :json,
          storage_dir: state_dir,
          repo_sources: {},
          manifest_schema_version: "1",
          required_manifest_schema_version: "1",
          preset_chain: [],
          preset_schema_versions: {},
          required_preset_schema_version: "1",
          secret_reference: "A3_SECRET"
        )

        result = described_class.new(runtime_package: runtime_package).call

        expect(result.status).to eq(:ok)
        expect(result.startup_readiness).to eq(:ready)
        expect(result.startup_blockers).to eq("none")
        state_root_check = result.checks.find { |check| check.name == :state_root }
        expect(state_root_check).to have_attributes(status: :ok, detail: "directory does not exist yet but can be created")
      end
    end
  end

  it "reports invalid_runtime when project runtime root is blocked by a file" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      project_runtime_root = File.join(dir, "project-root")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "presets: []\n")
      File.write(project_runtime_root, "not a directory\n")

      runtime_package = A3::Domain::RuntimePackageDescriptor.new(
        image_version: "a3:v2.1.0",
        manifest_path: manifest_path,
        project_runtime_root: project_runtime_root,
        preset_dir: preset_dir,
        storage_backend: :json,
        state_root: dir,
        workspace_root: File.join(dir, "workspaces"),
        artifact_root: File.join(dir, "artifacts"),
        repo_source_strategy: :none,
        repo_source_slots: [],
        repo_sources: {},
        distribution_image_ref: "a3-engine:a3:v2.1.0",
        runtime_entrypoint: "bin/a3",
        doctor_entrypoint: "bin/a3 doctor-runtime",
        migration_entrypoint: "bin/a3 migrate-scheduler-store",
        secret_delivery_mode: :environment_variable,
        secret_reference: "A3_SECRET",
        scheduler_store_migration_state: :not_required,
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1"
      )

      result = described_class.new(runtime_package: runtime_package).call

      expect(result.status).to eq(:invalid_runtime)
      project_root_check = result.checks.find { |check| check.name == :project_runtime_root }
      expect(project_root_check).to have_attributes(status: :invalid)
    end
  end

  it "accepts a non-writable project runtime root when it exists as a directory" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      project_runtime_root = File.join(dir, "project-root")
      FileUtils.mkdir_p(preset_dir)
      FileUtils.mkdir_p(project_runtime_root)
      File.write(manifest_path, "presets: []\n")
      FileUtils.chmod(0o555, project_runtime_root)

      runtime_package = A3::Domain::RuntimePackageDescriptor.new(
        image_version: "a3:v2.1.0",
        manifest_path: manifest_path,
        project_runtime_root: project_runtime_root,
        preset_dir: preset_dir,
        storage_backend: :json,
        state_root: dir,
        workspace_root: File.join(dir, "workspaces"),
        artifact_root: File.join(dir, "artifacts"),
        repo_source_strategy: :none,
        repo_source_slots: [],
        repo_sources: {},
        distribution_image_ref: "a3-engine:a3:v2.1.0",
        runtime_entrypoint: "bin/a3",
        doctor_entrypoint: "bin/a3 doctor-runtime",
        migration_entrypoint: "bin/a3 migrate-scheduler-store",
        secret_delivery_mode: :environment_variable,
        secret_reference: "A3_SECRET",
        scheduler_store_migration_state: :not_required,
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1"
      )

      result = described_class.new(runtime_package: runtime_package).call

      project_root_check = result.checks.find { |check| check.name == :project_runtime_root }
      expect(project_root_check).to have_attributes(status: :ok)
    ensure
      FileUtils.chmod(0o755, project_runtime_root) if File.exist?(project_runtime_root)
    end
  end

  it "reports invalid_runtime when explicit repo sources are missing" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "presets: []
")
      runtime_package = A3::Domain::RuntimePackageDescriptor.build(
        image_version: "a3:v2.1.0",
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: { repo_alpha: File.join(dir, "missing-repo-alpha") },
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1",
        secret_reference: "A3_SECRET"
      )

      result = described_class.new(runtime_package: runtime_package).call

      expect(result.status).to eq(:invalid_runtime)
      expect(result.repo_source_summary.fetch("strategy")).to eq(:explicit_map)
      expect(result.repo_source_summary.fetch("slots")).to eq([:repo_alpha])
      expect(result.repo_source_paths).to eq({ repo_alpha: File.join(dir, "missing-repo-alpha") })
      expect(result.repo_source_contract_summary).to eq("repo_source_strategy=explicit_map repo_source_slots=repo_alpha")
      repo_check = result.checks.find { |check| check.name == :"repo_source.repo_alpha" }
      expect(repo_check).to have_attributes(status: :missing)
      expect(result.contract_health).to eq("manifest_schema=ok preset_schema=ok repo_sources=missing secret_delivery=missing scheduler_store_migration=ok")
      expect(result.startup_blockers).to eq("repo_sources,secret_delivery")
      expect(result.next_command).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.recommended_execution_mode).to eq(:doctor_inspect)
      expect(result.recommended_execution_mode_reason).to eq("runtime is not ready; use doctor_inspect until blockers are resolved")
      expect(result.recommended_execution_mode_command).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.operator_guidance).to eq("startup blocked by repo_sources,secret_delivery; provide writable repo sources for repo_alpha; provide secrets via environment variable A3_SECRET; run bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
    end
  end

  it "reports invalid_runtime when explicit repo sources are not writable" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      repo_source_dir = File.join(dir, "repos", "repo-alpha")
      FileUtils.mkdir_p(preset_dir)
      FileUtils.mkdir_p(repo_source_dir)
      File.write(manifest_path, "presets: []\n")
      FileUtils.chmod(0o555, repo_source_dir)

      runtime_package = A3::Domain::RuntimePackageDescriptor.build(
        image_version: "a3:v2.1.0",
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: { repo_alpha: repo_source_dir },
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1",
        secret_reference: "A3_SECRET"
      )

      result = described_class.new(runtime_package: runtime_package).call

      expect(result.status).to eq(:invalid_runtime)
      repo_check = result.checks.find { |check| check.name == :"repo_source.repo_alpha" }
      expect(repo_check).to have_attributes(status: :not_writable)
      expect(result.contract_health).to eq("manifest_schema=ok preset_schema=ok repo_sources=not_writable secret_delivery=missing scheduler_store_migration=ok")
    ensure
      FileUtils.chmod(0o755, repo_source_dir) if File.exist?(repo_source_dir)
    end
  end

  it "reports invalid_runtime when a writable root is blocked by a file" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      workspace_root = File.join(dir, "workspaces")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "presets: []\n")
      File.write(workspace_root, "not a directory\n")
      runtime_package = A3::Domain::RuntimePackageDescriptor.build(
        image_version: "a3:v2.1.0",
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: {},
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1",
        secret_reference: "A3_SECRET"
      )

      result = described_class.new(runtime_package: runtime_package).call

      expect(result.status).to eq(:invalid_runtime)
      writable_root_check = result.checks.find { |check| check.name == :writable_root_workspace_root }
      expect(writable_root_check).to have_attributes(status: :invalid)
    end
  end

  it "reports invalid_runtime when scheduler store migration is pending" do
    with_env("A3_SECRET" => "token") do
      Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "presets: []\n")

      runtime_package = A3::Domain::RuntimePackageDescriptor.build(
        image_version: "a3:v2.1.0",
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: {},
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1",
        secret_reference: "A3_SECRET",
        scheduler_store_migration_state: :pending
      )

      result = described_class.new(runtime_package: runtime_package).call

      expect(result.status).to eq(:invalid_runtime)
      migration_check = result.checks.find { |check| check.name == :scheduler_store_migration }
      expect(migration_check).to have_attributes(status: :pending)
      expect(result.distribution_summary.fetch("scheduler_store_migration_state")).to eq(:pending)
      expect(result.contract_health).to eq("manifest_schema=ok preset_schema=ok repo_sources=ok secret_delivery=ok scheduler_store_migration=pending")
      expect(result.startup_readiness).to eq(:blocked)
      expect(result.startup_blockers).to eq("scheduler_store_migration")
      expect(result.recommended_execution_mode).to eq(:one_shot_cli)
      expect(result.recommended_execution_mode_reason).to eq("scheduler store migration is the only startup blocker; use one_shot_cli to apply migration and continue startup")
      expect(result.recommended_execution_mode_command).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.next_command).to eq("bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.runtime_validation_command_summary).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.startup_sequence).to eq("doctor=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} migrate=bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} runtime=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.operator_guidance).to eq("startup blocked by scheduler_store_migration; apply scheduler store migration before startup; run bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      end
    end
  end

  it "reports ok when a pending scheduler store migration marker is present" do
    with_env("A3_SECRET" => "token") do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "manifest.yml")
        preset_dir = File.join(dir, "presets")
        FileUtils.mkdir_p(preset_dir)
        File.write(manifest_path, "presets: []\n")

        runtime_package = A3::Domain::RuntimePackageDescriptor.build(
          image_version: "a3:v2.1.0",
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :json,
          storage_dir: dir,
          repo_sources: {},
          manifest_schema_version: "1",
          required_manifest_schema_version: "1",
          preset_chain: [],
          preset_schema_versions: {},
          required_preset_schema_version: "1",
          secret_reference: "A3_SECRET",
          scheduler_store_migration_state: :pending
        )
        FileUtils.mkdir_p(runtime_package.migration_marker_path.dirname)
        File.write(runtime_package.migration_marker_path, "applied\n")

        result = described_class.new(runtime_package: runtime_package).call

        expect(result.status).to eq(:ok)
        expect(result.startup_readiness).to eq(:ready)
        expect(result.startup_blockers).to eq("none")
        expect(result.recommended_execution_mode).to eq(:one_shot_cli)
        expect(result.next_command).to eq("bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
        expect(result.runtime_validation_command_summary).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} && bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
        expect(result.startup_sequence).to eq("doctor=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir} migrate=skip runtime=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      end
    end
  end

  it "reports invalid_runtime when environment variable secret delivery is missing" do
    with_env("A3_SECRET" => nil) do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "manifest.yml")
        preset_dir = File.join(dir, "presets")
        FileUtils.mkdir_p(preset_dir)
        File.write(manifest_path, "presets: []\n")

        runtime_package = A3::Domain::RuntimePackageDescriptor.build(
          image_version: "a3:v2.1.0",
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :json,
          storage_dir: dir,
          repo_sources: {},
          manifest_schema_version: "1",
          required_manifest_schema_version: "1",
          preset_chain: [],
          preset_schema_versions: {},
          required_preset_schema_version: "1",
        secret_reference: "A3_SECRET"
        )

        result = described_class.new(runtime_package: runtime_package).call

        expect(result.status).to eq(:invalid_runtime)
        secret_check = result.checks.find { |check| check.name == :secret_delivery }
        expect(secret_check).to have_attributes(status: :missing)
        expect(result.contract_health).to eq("manifest_schema=ok preset_schema=ok repo_sources=ok secret_delivery=missing scheduler_store_migration=ok")
        expect(result.startup_readiness).to eq(:invalid)
        expect(result.startup_blockers).to eq("secret_delivery")
        expect(result.recommended_execution_mode).to eq(:doctor_inspect)
        expect(result.next_command).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
        expect(result.operator_guidance).to eq("startup blocked by secret_delivery; provide secrets via environment variable A3_SECRET; run bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      end
    end
  end

  it "reports ok when file mounted secret exists and is readable" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      secret_path = File.join(dir, "secrets", "a3-runtime")
      FileUtils.mkdir_p(preset_dir)
      FileUtils.mkdir_p(File.dirname(secret_path))
      File.write(manifest_path, "presets: []\n")
      File.write(secret_path, "token\n")

      runtime_package = A3::Domain::RuntimePackageDescriptor.build(
        image_version: "a3:v2.1.0",
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: {},
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1",
        secret_delivery_mode: :file_mount,
        secret_reference: secret_path
      )

      result = described_class.new(runtime_package: runtime_package).call

      expect(result.status).to eq(:ok)
      secret_check = result.checks.find { |check| check.name == :secret_delivery }
      expect(secret_check).to have_attributes(status: :ok)
    end
  end
end
