# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::CLI do
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

  it "responds to start" do
    expect(described_class).to respond_to(:start)
  end

  it "routes known commands through the command dispatcher" do
    out = StringIO.new
    allow(described_class).to receive(:handle_show_task)

    described_class.start(
      ["show-task", "A3-v2#3025"],
      out: out
    )

    expect(described_class).to have_received(:handle_show_task).with(
      ["A3-v2#3025"],
      out: out,
      run_id_generator: kind_of(Proc),
      command_runner: an_instance_of(A3::Infra::LocalCommandRunner),
      merge_runner: an_instance_of(A3::Infra::DisabledMergeRunner)
    )
  end

  it "routes manifest-driven runtime commands through the shared runtime session helper" do
    out = StringIO.new
    session = Struct.new(:options, :container, :project_context, :project_surface, keyword_init: true).new(
      options: {
        task_ref: "A3-v2#3025",
        run_ref: "run-1",
        manifest_path: "/tmp/manifest.yml",
        preset_dir: "/tmp/presets"
      },
      container: {
        build_merge_plan: instance_double(
          A3::Application::BuildMergePlan,
          call: Struct.new(:merge_plan).new(
            Struct.new(:merge_source, :integration_target, :merge_policy, :merge_slots).new(
              Struct.new(:source_ref).new("refs/heads/a3/work/A3-v2-3025"),
              Struct.new(:target_ref).new("refs/heads/a3/parent/A3-v2#3022"),
              :ff_only,
              [:repo_alpha]
            )
          )
        )
      },
      project_context: Object.new,
      project_surface: Object.new
    )
    allow(described_class).to receive(:with_runtime_session).and_yield(session)

    described_class.start(
      ["show-merge-plan", "A3-v2#3025", "run-1", "/tmp/manifest.yml", "--preset-dir", "/tmp/presets"],
      out: out
    )

    expect(described_class).to have_received(:with_runtime_session)
    expect(out.string).to include("merge_source=refs/heads/a3/work/A3-v2-3025")
  end

  it "uses a shared default storage dir for start-run parsing" do
    allow(Dir).to receive(:pwd).and_return("/tmp/current")

    options = described_class.send(:parse_start_run_options, ["A3-v2#3025", "implementation"])

    expect(options.fetch(:storage_dir)).to eq("/tmp/current/tmp/a3-v2")
  end

  it "uses a shared default storage dir for execute-until-idle parsing" do
    allow(Dir).to receive(:pwd).and_return("/tmp/current")

    options = described_class.send(:parse_execute_until_idle_options, ["/tmp/runtime/manifest.yml"])

    expect(options.fetch(:storage_dir)).to eq("/tmp/current/tmp/a3-v2")
  end

  it "keeps explicit storage-dir overrides after centralizing defaults" do
    options = described_class.send(
      :parse_execute_until_idle_options,
      ["--storage-dir", "/tmp/custom-state", "/tmp/runtime/manifest.yml"]
    )

    expect(options.fetch(:storage_dir)).to eq("/tmp/custom-state")
  end

  it "builds a subprocess-cli kanban bridge bundle" do
    Dir.mktmpdir do |dir|
      bundle = described_class.send(
        :build_external_task_bridge,
        {
          kanban_backend: "subprocess-cli",
          kanban_command: "task",
          kanban_command_args: ["kanban:api", "--"],
          kanban_project: "Portal",
          kanban_repo_label_map: { "repo:ui-app" => ["repo_beta"] },
          kanban_trigger_labels: ["trigger:auto-implement"],
          kanban_working_dir: dir
        }
      )

      expect(bundle.task_source).to be_a(A3::Infra::KanbanCliTaskSource)
      expect(bundle.task_status_publisher).to be_a(A3::Infra::KanbanCliTaskStatusPublisher)
      expect(bundle.task_activity_publisher).to be_a(A3::Infra::KanbanCliTaskActivityPublisher)
      expect(bundle.follow_up_child_writer).to be_a(A3::Infra::KanbanCliFollowUpChildWriter)
      expect(bundle.task_snapshot_reader).to be_a(A3::Infra::KanbanCliTaskSnapshotReader)
    end
  end

  it "rejects unsupported kanban backends" do
    expect do
      described_class.send(
        :build_external_task_bridge,
        {
          kanban_backend: "unknown",
          kanban_command: "task",
          kanban_command_args: ["kanban:api", "--"],
          kanban_project: "Portal",
          kanban_repo_label_map: { "repo:ui-app" => ["repo_beta"] },
          kanban_trigger_labels: ["trigger:auto-implement"]
        }
      )
    end.to raise_error(ArgumentError, /Unsupported kanban backend: unknown/)
  end





  it "reports runtime doctor status through the shared runtime session helper" do
    with_env("A3_SECRET" => "token") do
      Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, 'manifest.yml')
      preset_dir = File.join(dir, 'presets')
      repo_source_dir = File.join(dir, 'repos', 'repo-alpha')
      FileUtils.mkdir_p(preset_dir)
      FileUtils.mkdir_p(repo_source_dir)
      File.write(manifest_path, "schema_version: 1\npresets: []\n")
      out = StringIO.new
      descriptor = A3::Domain::RuntimePackageDescriptor.build(
        image_version: 'a3:v2.1.0',
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :sqlite,
        storage_dir: dir,
        repo_sources: {repo_alpha: repo_source_dir},
        manifest_schema_version: '1',
        required_manifest_schema_version: '1',
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: '1',
        secret_reference: 'A3_SECRET'
      )
      session = Struct.new(:options, :runtime_package, :runtime_environment_config, keyword_init: true).new(
        options: {
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :sqlite,
          storage_dir: dir
        },
        runtime_package: descriptor,
        runtime_environment_config: A3::Bootstrap::RuntimeEnvironmentConfig.runtime_only(runtime_package: descriptor)
      )
      allow(described_class).to receive(:with_runtime_package_session).and_yield(session)

    described_class.start(
      ['doctor-runtime', manifest_path, '--preset-dir', preset_dir, '--storage-backend', 'sqlite', '--storage-dir', dir],
      out: out
    )

      expect(described_class).to have_received(:with_runtime_package_session)
      expect(out.string).to include('runtime_doctor=ok')
      expect(out.string).to include("project_runtime_root=#{File.dirname(manifest_path)}")
      expect(out.string).to include("runtime_summary.mount=state_root=#{dir} logs_root=#{File.join(dir, 'logs')} workspace_root=#{File.join(dir, 'workspaces')} artifact_root=#{File.join(dir, 'artifacts')} migration_marker_path=#{File.join(dir, '.a3', 'scheduler-store-migration.applied')}")
      expect(out.string).to include("runtime_summary.writable_roots=#{dir},#{File.join(dir, 'workspaces')},#{File.join(dir, 'artifacts')}")
      expect(out.string).to include("runtime_summary.repo_sources=#{descriptor.operator_summary.fetch('repo_sources')}")
      expect(out.string).to include("runtime_summary.distribution=#{descriptor.operator_summary.fetch('distribution')}")
      expect(out.string).to include("runtime_summary.persistent_state_model=#{descriptor.operator_summary.fetch('persistent_state_model')}")
      expect(out.string).to include("runtime_summary.retention_policy=#{descriptor.operator_summary.fetch('retention_policy')}")
      expect(out.string).to include("runtime_summary.materialization_model=#{descriptor.operator_summary.fetch('materialization_model')}")
      expect(out.string).to include("runtime_summary.runtime_configuration_model=#{descriptor.operator_summary.fetch('runtime_configuration_model')}")
      expect(out.string).to include("runtime_summary.repository_metadata_model=#{descriptor.operator_summary.fetch('repository_metadata_model')}")
      expect(out.string).to include("runtime_summary.branch_resolution_model=#{descriptor.operator_summary.fetch('branch_resolution_model')}")
      expect(out.string).to include("runtime_summary.credential_boundary_model=#{descriptor.operator_summary.fetch('credential_boundary_model')}")
      expect(out.string).to include("runtime_summary.observability_boundary_model=#{descriptor.operator_summary.fetch('observability_boundary_model')}")
      expect(out.string).to include("runtime_summary.deployment_shape=#{descriptor.operator_summary.fetch('deployment_shape')}")
      expect(out.string).to include("runtime_summary.networking_boundary=#{descriptor.operator_summary.fetch('networking_boundary')}")
      expect(out.string).to include("runtime_summary.upgrade_contract=#{descriptor.operator_summary.fetch('upgrade_contract')}")
      expect(out.string).to include("runtime_summary.fail_fast_policy=#{descriptor.operator_summary.fetch('fail_fast_policy')}")
      expect(out.string).to include("runtime_summary.schema_contract=#{descriptor.operator_summary.fetch('schema_contract')}")
      expect(out.string).to include("runtime_summary.preset_schema_contract=#{descriptor.operator_summary.fetch('preset_schema_contract')}")
      expect(out.string).to include("runtime_summary.repo_source_contract=#{descriptor.operator_summary.fetch('repo_source_contract')}")
      expect(out.string).to include("runtime_summary.secret_contract=#{descriptor.operator_summary.fetch('secret_contract')}")
      expect(out.string).to include("runtime_summary.migration_contract=#{descriptor.operator_summary.fetch('migration_contract')}")
      expect(out.string).to include("runtime_summary.runtime_contract=#{descriptor.operator_summary.fetch('runtime_contract')}")
      expect(out.string).to include("runtime_summary.repo_source_action=#{descriptor.operator_summary.fetch('repo_source_action')}")
      expect(out.string).to include("runtime_summary.preset_schema_action=#{descriptor.operator_summary.fetch('preset_schema_action')}")
      expect(out.string).to include("runtime_summary.secret_delivery_action=#{descriptor.operator_summary.fetch('secret_delivery_action')}")
      expect(out.string).to include("runtime_summary.scheduler_store_migration_action=#{descriptor.operator_summary.fetch('scheduler_store_migration_action')}")
      expect(out.string).to include("runtime_summary.startup_checklist=#{descriptor.operator_summary.fetch('startup_checklist')}")
      expect(out.string).to include("runtime_summary.execution_modes=#{descriptor.operator_summary.fetch('execution_modes')}")
      expect(out.string).to include("runtime_summary.execution_mode_contract=#{descriptor.operator_summary.fetch('execution_mode_contract')}")
      expect(out.string).to include("runtime_summary.startup_readiness=ready")
      expect(out.string).to include("runtime_summary.recommended_execution_mode=one_shot_cli")
      expect(out.string).to include("runtime_summary.recommended_execution_mode_reason=runtime contract satisfied; use one_shot_cli to validate execution or start scheduler processing")
      expect(out.string).to include("runtime_summary.recommended_execution_mode_command=#{descriptor.operator_summary.fetch('runtime_canary_command')}")
      expect(out.string).to include("runtime_summary.doctor_command=#{descriptor.operator_summary.fetch('doctor_command')}")
      expect(out.string).to include("runtime_summary.migration_command=#{descriptor.operator_summary.fetch('migration_command')}")
      expect(out.string).to include("runtime_summary.runtime_command=#{descriptor.operator_summary.fetch('runtime_command')}")
      expect(out.string).to include("runtime_summary.runtime_canary_command=#{descriptor.operator_summary.fetch('runtime_canary_command')}")
      expect(out.string).to include("runtime_summary.next_command=#{descriptor.operator_summary.fetch('runtime_command')}")
      expect(out.string).to include("runtime_summary.startup_sequence=#{descriptor.operator_summary.fetch('startup_sequence')}")
      expect(out.string).to include("runtime_summary.operator_action=#{descriptor.operator_summary.fetch('operator_action')}")
      expect(out.string).to include("runtime_summary.contract_health=manifest_schema=ok preset_schema=ok repo_sources=ok secret_delivery=ok scheduler_store_migration=ok")
      expect(out.string).to include("runtime_summary.operator_guidance=startup ready; runtime package contract satisfied")
      expect(out.string).to include("runtime_summary.startup_blockers=none")
      expect(out.string).to include("distribution_summary.image_ref=#{descriptor.distribution_summary.fetch('image_ref')}")
      expect(out.string).to include("distribution_summary.runtime_entrypoint=#{descriptor.distribution_summary.fetch('runtime_entrypoint')}")
      expect(out.string).to include("distribution_summary.doctor_entrypoint=#{descriptor.distribution_summary.fetch('doctor_entrypoint')}")
      expect(out.string).to include("distribution_summary.migration_entrypoint=#{descriptor.distribution_summary.fetch('migration_entrypoint')}")
      expect(out.string).to include("distribution_summary.manifest_schema_version=#{descriptor.distribution_summary.fetch('manifest_schema_version')}")
      expect(out.string).to include("distribution_summary.required_manifest_schema_version=#{descriptor.distribution_summary.fetch('required_manifest_schema_version')}")
      expect(out.string).to include("distribution_summary.schema_contract=#{descriptor.distribution_summary.fetch('schema_contract')}")
      expect(out.string).to include("distribution_summary.preset_chain=#{descriptor.distribution_summary.fetch('preset_chain').join(',')}")
      expect(out.string).to include("distribution_summary.preset_schema_versions=#{descriptor.distribution_summary.fetch('preset_schema_versions').map { |preset, version| "#{preset}=#{version}" }.join(',')}")
      expect(out.string).to include("distribution_summary.required_preset_schema_version=#{descriptor.distribution_summary.fetch('required_preset_schema_version')}")
      expect(out.string).to include("distribution_summary.preset_schema_contract=#{descriptor.distribution_summary.fetch('preset_schema_contract')}")
      expect(out.string).to include("distribution_summary.secret_delivery_mode=#{descriptor.distribution_summary.fetch('secret_delivery_mode')}")
      expect(out.string).to include("distribution_summary.secret_reference=#{descriptor.distribution_summary.fetch('secret_reference')}")
      expect(out.string).to include("distribution_summary.secret_contract=#{descriptor.distribution_summary.fetch('secret_contract')}")
      expect(out.string).to include("distribution_summary.scheduler_store_migration_state=#{descriptor.distribution_summary.fetch('scheduler_store_migration_state')}")
      expect(out.string).to include("distribution_summary.migration_contract=#{descriptor.distribution_summary.fetch('migration_contract')}")
      expect(out.string).to include("distribution_summary.persistent_state_model=#{descriptor.distribution_summary.fetch('persistent_state_model')}")
      expect(out.string).to include("distribution_summary.retention_policy=#{descriptor.distribution_summary.fetch('retention_policy')}")
      expect(out.string).to include("distribution_summary.materialization_model=#{descriptor.distribution_summary.fetch('materialization_model')}")
      expect(out.string).to include("distribution_summary.runtime_configuration_model=#{descriptor.distribution_summary.fetch('runtime_configuration_model')}")
      expect(out.string).to include("distribution_summary.repository_metadata_model=#{descriptor.distribution_summary.fetch('repository_metadata_model')}")
      expect(out.string).to include("distribution_summary.branch_resolution_model=#{descriptor.distribution_summary.fetch('branch_resolution_model')}")
      expect(out.string).to include("distribution_summary.credential_boundary_model=#{descriptor.distribution_summary.fetch('credential_boundary_model')}")
      expect(out.string).to include("distribution_summary.observability_boundary_model=#{descriptor.distribution_summary.fetch('observability_boundary_model')}")
      expect(out.string).to include("distribution_summary.deployment_shape=#{descriptor.distribution_summary.fetch('deployment_shape')}")
      expect(out.string).to include("distribution_summary.networking_boundary=#{descriptor.distribution_summary.fetch('networking_boundary')}")
      expect(out.string).to include("distribution_summary.upgrade_contract=#{descriptor.distribution_summary.fetch('upgrade_contract')}")
      expect(out.string).to include("distribution_summary.fail_fast_policy=#{descriptor.distribution_summary.fetch('fail_fast_policy')}")
      expect(out.string).to include("writable_roots=#{dir},#{File.join(dir, 'workspaces')},#{File.join(dir, 'artifacts')}")
      expect(out.string).to include("mount_summary.state_root=#{dir}")
      expect(out.string).to include("mount_summary.logs_root=#{File.join(dir, 'logs')}")
      expect(out.string).to include("repo_source_paths=repo_alpha=#{repo_source_dir}")
      expect(out.string).to include('repo_source_details=explicit_map:repo_alpha')
      expect(out.string).to include('check.manifest_path=ok')
      end
    end
  end

  it "prints a runtime package descriptor through the shared runtime session helper" do
    out = StringIO.new
    descriptor = A3::Domain::RuntimePackageDescriptor.build(
      image_version: 'a3:v2.1.0',
      manifest_path: '/tmp/runtime/manifest.yml',
      preset_dir: '/tmp/runtime/presets',
      storage_backend: :sqlite,
      storage_dir: '/tmp/runtime/state',
      repo_sources: {repo_alpha: '/tmp/repos/repo-alpha', repo_beta: '/tmp/repos/repo-beta'},
      manifest_schema_version: '1',
      required_manifest_schema_version: '1',
      preset_chain: [],
      preset_schema_versions: {},
      required_preset_schema_version: '1',
        secret_reference: 'A3_SECRET'
    )
    session = Struct.new(:options, :runtime_package, keyword_init: true).new(
      options: {
        manifest_path: '/tmp/runtime/manifest.yml',
        preset_dir: '/tmp/runtime/presets',
        storage_backend: :sqlite,
        storage_dir: '/tmp/runtime/state'
      },
      runtime_package: descriptor
    )
    allow(described_class).to receive(:with_runtime_package_session).and_yield(session)

    described_class.start(
      ['show-runtime-package', '/tmp/runtime/manifest.yml', '--preset-dir', '/tmp/runtime/presets', '--storage-backend', 'sqlite', '--storage-dir', '/tmp/runtime/state'],
      out: out
    )

    expect(described_class).to have_received(:with_runtime_package_session)
    expect(out.string).to include('image_version=a3:v2.1.0')
    expect(out.string).to include('manifest_path=/tmp/runtime/manifest.yml')
    expect(out.string).to include('project_runtime_root=/tmp/runtime')
    expect(out.string).to include('runtime_summary.mount=state_root=/tmp/runtime/state logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts migration_marker_path=/tmp/runtime/state/.a3/scheduler-store-migration.applied')
    expect(out.string).to include('runtime_summary.writable_roots=/tmp/runtime/state,/tmp/runtime/state/workspaces,/tmp/runtime/state/artifacts')
    expect(out.string).to include('runtime_summary.repo_sources=strategy=explicit_map slots=repo_alpha,repo_beta paths=repo_alpha=/tmp/repos/repo-alpha,repo_beta=/tmp/repos/repo-beta')
    expect(out.string).to include('runtime_summary.distribution=image_ref=a3-engine:a3:v2.1.0 runtime_entrypoint=bin/a3 doctor_entrypoint=bin/a3 doctor-runtime')
    expect(out.string).to include('runtime_summary.persistent_state_model=scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts')
    expect(out.string).to include('runtime_summary.retention_policy=terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none')
    expect(out.string).to include('runtime_summary.materialization_model=repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start')
    expect(out.string).to include('runtime_summary.runtime_configuration_model=manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required')
    expect(out.string).to include('runtime_summary.deployment_shape=runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project')
    expect(out.string).to include('runtime_summary.networking_boundary=outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project')
    expect(out.string).to include('runtime_summary.upgrade_contract=image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit')
    expect(out.string).to include('runtime_summary.fail_fast_policy=manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast')
    expect(out.string).to include('runtime_summary.repo_source_contract=repo_source_strategy=explicit_map repo_source_slots=repo_alpha,repo_beta')
    expect(out.string).to include('runtime_summary.secret_contract=secret_delivery_mode=environment_variable secret_reference=A3_SECRET')
    expect(out.string).to include('runtime_summary.migration_contract=scheduler_store_migration_state=not_required')
    expect(out.string).to include('runtime_summary.schema_contract=manifest_schema_version=1 required_manifest_schema_version=1')
    expect(out.string).to include('runtime_summary.preset_schema_contract=required_preset_schema_version=1 preset_schema_versions=')
    expect(out.string).to include('runtime_summary.runtime_contract=manifest_schema_version=1 required_manifest_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=explicit_map repo_source_slots=repo_alpha,repo_beta secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=not_required')
    expect(out.string).to include('runtime_summary.credential_boundary_model=secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only')
    expect(out.string).to include('runtime_summary.observability_boundary_model=operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only')
    expect(out.string).to include('runtime_summary.repo_source_action=provide writable repo sources for repo_alpha,repo_beta')
    expect(out.string).to include('runtime_summary.preset_schema_action=no preset schema action required')
    expect(out.string).to include('runtime_summary.secret_delivery_action=provide secrets via environment variable A3_SECRET')
    expect(out.string).to include('runtime_summary.scheduler_store_migration_action=scheduler store migration not required')
    expect(out.string).to include('runtime_summary.startup_checklist=provide writable repo sources for repo_alpha,repo_beta; provide secrets via environment variable A3_SECRET; scheduler store migration not required')
    expect(out.string).to include("runtime_summary.execution_modes=#{descriptor.operator_summary.fetch('execution_modes')}")
    expect(out.string).to include("runtime_summary.execution_mode_contract=#{descriptor.operator_summary.fetch('execution_mode_contract')}")
    expect(out.string).to include('runtime_summary.descriptor_startup_readiness=descriptor_ready')
    expect(out.string).to include('runtime_summary.doctor_command=bin/a3 doctor-runtime /tmp/runtime/manifest.yml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.migration_command=bin/a3 migrate-scheduler-store /tmp/runtime/manifest.yml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.runtime_command=bin/a3 execute-until-idle /tmp/runtime/manifest.yml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.runtime_canary_command=bin/a3 doctor-runtime /tmp/runtime/manifest.yml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state && bin/a3 execute-until-idle /tmp/runtime/manifest.yml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.startup_sequence=doctor=bin/a3 doctor-runtime /tmp/runtime/manifest.yml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state migrate=skip runtime=bin/a3 execute-until-idle /tmp/runtime/manifest.yml --preset-dir /tmp/runtime/presets --storage-backend sqlite --storage-dir /tmp/runtime/state')
    expect(out.string).to include('runtime_summary.operator_action=provide writable repo sources for repo_alpha,repo_beta; provide secrets via environment variable A3_SECRET; scheduler store migration not required')
    expect(out.string).to include('distribution_summary.image_ref=a3-engine:a3:v2.1.0')
    expect(out.string).to include('distribution_summary.runtime_entrypoint=bin/a3')
    expect(out.string).to include('distribution_summary.doctor_entrypoint=bin/a3 doctor-runtime')
    expect(out.string).to include('distribution_summary.migration_entrypoint=bin/a3 migrate-scheduler-store')
    expect(out.string).to include('distribution_summary.preset_chain=')
    expect(out.string).to include('distribution_summary.preset_schema_versions=')
    expect(out.string).to include('distribution_summary.required_preset_schema_version=1')
    expect(out.string).to include('distribution_summary.preset_schema_contract=required_preset_schema_version=1 preset_schema_versions=')
    expect(out.string).to include('distribution_summary.secret_delivery_mode=environment_variable')
    expect(out.string).to include('distribution_summary.secret_reference=A3_SECRET')
    expect(out.string).to include('distribution_summary.secret_contract=secret_delivery_mode=environment_variable secret_reference=A3_SECRET')
    expect(out.string).to include('distribution_summary.credential_boundary_model=secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only')
    expect(out.string).to include('distribution_summary.observability_boundary_model=operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only')
    expect(out.string).to include('distribution_summary.scheduler_store_migration_state=not_required')
    expect(out.string).to include('distribution_summary.migration_contract=scheduler_store_migration_state=not_required')
    expect(out.string).to include('writable_roots=/tmp/runtime/state,/tmp/runtime/state/workspaces,/tmp/runtime/state/artifacts')
    expect(out.string).to include('repo_source_paths=repo_alpha=/tmp/repos/repo-alpha,repo_beta=/tmp/repos/repo-beta')
    expect(out.string).to include('repo_source_strategy=explicit_map')
    expect(out.string).to include('repo_source_slots=repo_alpha,repo_beta')
    expect(out.string).to include('repo_source_details=explicit_map:repo_alpha,repo_beta')
  end

  it "runs scheduler store migration through the shared runtime package session helper" do
    out = StringIO.new
    runtime_package = instance_double(
      A3::Domain::RuntimePackageDescriptor,
      scheduler_store_migration_state: :pending
    )
    session = Struct.new(:options, :runtime_package, keyword_init: true).new(
      options: {
        manifest_path: "/tmp/runtime/manifest.yml",
        preset_dir: "/tmp/runtime/presets",
        storage_backend: :sqlite,
        storage_dir: "/tmp/runtime/state"
      },
      runtime_package: runtime_package
    )
    allow(described_class).to receive(:with_runtime_package_session).and_yield(session)
    result = Struct.new(:status, :migration_state, :marker_path, :message).new(
      :applied,
      :applied,
      Pathname("/tmp/runtime/state/.a3/scheduler-store-migration.applied"),
      "scheduler store migration marker written"
    )
    allow(A3::Application::MigrateSchedulerStore).to receive(:new).with(runtime_package: runtime_package).and_return(
      instance_double(A3::Application::MigrateSchedulerStore, call: result)
    )

    described_class.start(
      ["migrate-scheduler-store", "/tmp/runtime/manifest.yml", "--preset-dir", "/tmp/runtime/presets", "--storage-backend", "sqlite", "--storage-dir", "/tmp/runtime/state"],
      out: out
    )

    expect(out.string).to include("scheduler_store_migration=applied")
    expect(out.string).to include("migration_state=applied")
    expect(out.string).to include("migration_marker_path=/tmp/runtime/state/.a3/scheduler-store-migration.applied")
    expect(out.string).to include("message=scheduler store migration marker written")
  end

  it "runs runtime canary through the shared runtime session helper" do
    out = StringIO.new
    runtime_package = instance_double(
      A3::Domain::RuntimePackageDescriptor,
      image_version: "a3:v2.1.0",
      project_runtime_root: Pathname("/tmp/runtime"),
      storage_backend: :sqlite,
      writable_roots: [
        Pathname("/tmp/runtime/state"),
        Pathname("/tmp/runtime/state/workspaces"),
        Pathname("/tmp/runtime/state/artifacts")
      ],
      operator_summary: {
        "schema_contract" => "manifest_schema_version=1 required_manifest_schema_version=1",
        "preset_schema_contract" => "required_preset_schema_version=1 preset_schema_versions=",
        "repo_source_contract" => "repo_source_strategy=explicit_map repo_source_slots=repo_alpha",
        "secret_contract" => "secret_delivery_mode=environment_variable secret_reference=A3_SECRET",
        "migration_contract" => "scheduler_store_migration_state=not_required",
        "runtime_contract" => "manifest_schema_version=1 required_manifest_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=explicit_map repo_source_slots=repo_alpha secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=not_required",
        "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        "observability_boundary_model" => "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only",
        "repo_source_action" => "provide writable repo sources for repo_alpha,repo_beta",
        "preset_schema_action" => "no preset schema action required",
        "secret_delivery_action" => "provide secrets via environment variable A3_SECRET",
        "scheduler_store_migration_action" => "scheduler store migration not required",
        "startup_checklist" => "provide writable repo sources for repo_alpha,repo_beta; provide secrets via environment variable A3_SECRET; scheduler store migration not required",
        "execution_modes" => "one_shot_cli=bin/a3 doctor-runtime ... | bin/a3 migrate-scheduler-store ... | bin/a3 execute-until-idle ... ; scheduler_loop=bin/a3 execute-until-idle ... ; doctor_inspect=bin/a3 doctor-runtime ...",
        "execution_mode_contract" => "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
        "doctor_command" => "bin/a3 doctor-runtime ...",
        "migration_command" => "bin/a3 migrate-scheduler-store ...",
        "runtime_command" => "bin/a3 execute-until-idle ...",
        "operator_action" => "provide writable repo sources for repo_alpha,repo_beta; provide secrets via environment variable A3_SECRET; scheduler store migration not required"
      }
    )
    session = Struct.new(:options, :container, :project_context, :runtime_package, keyword_init: true).new(
      options: {
        manifest_path: "/tmp/runtime/manifest.yml",
        preset_dir: "/tmp/runtime/presets",
        storage_backend: :sqlite,
        storage_dir: "/tmp/runtime/state",
        max_steps: 5
      },
      container: {
        execute_until_idle: instance_double(A3::Application::ExecuteUntilIdle)
      },
      project_context: Object.new,
      runtime_package: runtime_package
    )
    allow(described_class).to receive(:with_runtime_session).and_yield(session)
    result = A3::Application::RunRuntimeCanary::Result.new(
      status: :completed,
      doctor_result: Struct.new(
        :contract_health,
        :mount_summary,
        :repo_source_strategy,
        :repo_source_slots,
        :repo_source_paths,
        :repo_source_summary,
        :startup_readiness,
        :startup_blockers,
        :execution_modes_summary,
        :execution_mode_contract_summary,
        :distribution_summary,
        :recommended_execution_mode,
        :recommended_execution_mode_reason,
        :recommended_execution_mode_command,
        :operator_guidance,
        :next_command,
        :doctor_command_summary,
        :migration_command_summary,
        :runtime_command_summary,
        :startup_sequence,
        :runtime_canary_command_summary,
        :checks
      ).new(
        "repo_sources=ok secret_delivery=ok scheduler_store_migration=ok",
        {
          "state_root" => "/tmp/runtime/state",
          "logs_root" => "/tmp/runtime/state/logs",
          "workspace_root" => "/tmp/runtime/state/workspaces",
          "artifact_root" => "/tmp/runtime/state/artifacts",
          "migration_marker_path" => "/tmp/runtime/state/.a3/scheduler-store-migration.applied"
        },
        :explicit_map,
        [:repo_alpha],
        { repo_alpha: "/tmp/repos/repo-alpha" },
        {
          "strategy" => :explicit_map,
          "slots" => [:repo_alpha],
          "sources" => { repo_alpha: "/tmp/repos/repo-alpha" }
        },
        :ready,
        "none",
        "one_shot_cli=bin/a3 doctor-runtime ... | bin/a3 migrate-scheduler-store ... | bin/a3 execute-until-idle ... ; scheduler_loop=bin/a3 execute-until-idle ... ; doctor_inspect=bin/a3 doctor-runtime ...",
        "one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only",
        {
          "image_ref" => "a3-engine:a3:v2.1.0",
          "runtime_entrypoint" => "bin/a3",
          "doctor_entrypoint" => "bin/a3 doctor-runtime",
          "migration_entrypoint" => "bin/a3 migrate-scheduler-store",
          "manifest_schema_version" => "1",
          "required_manifest_schema_version" => "1",
          "schema_contract" => "manifest_schema_version=1 required_manifest_schema_version=1",
          "preset_chain" => [],
          "preset_schema_versions" => {},
          "required_preset_schema_version" => "1",
          "preset_schema_contract" => "required_preset_schema_version=1 preset_schema_versions=",
          "secret_delivery_mode" => :environment_variable,
          "secret_reference" => "A3_SECRET",
          "secret_contract" => "secret_delivery_mode=environment_variable secret_reference=A3_SECRET",
          "scheduler_store_migration_state" => :not_required,
          "migration_contract" => "scheduler_store_migration_state=not_required",
          "persistent_state_model" => "scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts",
          "retention_policy" => "terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none",
          "materialization_model" => "repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start",
          "runtime_configuration_model" => "manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required",
        "repository_metadata_model" => "repository_metadata=runtime_package_scoped source_descriptor_ref_resolution=required review_target_resolution=evidence_driven",
        "branch_resolution_model" => "authoritative_branch_resolution=runtime_package_scoped integration_target_resolution=runtime_package_scoped branch_integration_inputs=required",
        "credential_boundary_model" => "secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only",
        "observability_boundary_model" => "operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only",
        "deployment_shape" => "runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project",
          "networking_boundary" => "outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project",
          "upgrade_contract" => "image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit",
          "fail_fast_policy" => "manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast"
        },
        :one_shot_cli,
        "runtime contract satisfied; use one_shot_cli to validate execution or start scheduler processing",
        "bin/a3 doctor-runtime ... && bin/a3 execute-until-idle ...",
        "startup ready; runtime package contract satisfied; run bin/a3 execute-until-idle ...",
        "bin/a3 execute-until-idle ...",
        "bin/a3 doctor-runtime ...",
        "bin/a3 migrate-scheduler-store ...",
        "bin/a3 execute-until-idle ...",
        "doctor=bin/a3 doctor-runtime ... migrate=skip runtime=bin/a3 execute-until-idle ...",
        "bin/a3 doctor-runtime ... && bin/a3 execute-until-idle ...",
        [Struct.new(:name, :status, :path, :detail).new(:manifest_path, :ok, "/tmp/runtime/manifest.yml", "file exists")]
      ),
      migration_result: Struct.new(:status, :marker_path).new(:applied, Pathname("/tmp/runtime/state/.a3/scheduler-store-migration.applied")),
      scheduler_result: Struct.new(:executed_count, :idle_reached, :stop_reason, :quarantined_count).new(4, true, :idle, 1),
      operator_action: :start_continuous_processing,
      operator_action_command: "bin/a3 execute-until-idle ...",
      next_execution_mode: :scheduler_loop,
      next_execution_mode_reason: "runtime canary completed with a ready runtime; continue scheduler loop for ongoing runnable processing",
      next_execution_mode_command: "bin/a3 execute-until-idle ..."
    )
    allow(A3::Application::RunRuntimeCanary).to receive(:new).and_return(
      instance_double(A3::Application::RunRuntimeCanary, call: result)
    )

    described_class.start(
      ["run-runtime-canary", "/tmp/runtime/manifest.yml", "--preset-dir", "/tmp/runtime/presets", "--storage-backend", "sqlite", "--storage-dir", "/tmp/runtime/state", "--max-steps", "5"],
      out: out
    )

    expect(out.string).to include("runtime_canary=completed")
    expect(out.string).to include("image_version=a3:v2.1.0")
    expect(out.string).to include("project_runtime_root=/tmp/runtime")
    expect(out.string).to include("storage_backend=sqlite")
    expect(out.string).to include("writable_roots=/tmp/runtime/state,/tmp/runtime/state/workspaces,/tmp/runtime/state/artifacts")
    expect(out.string).to include("runtime_summary.contract_health=repo_sources=ok secret_delivery=ok scheduler_store_migration=ok")
    expect(out.string).to include("runtime_summary.mount=state_root=/tmp/runtime/state logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts migration_marker_path=/tmp/runtime/state/.a3/scheduler-store-migration.applied")
    expect(out.string).to include("runtime_summary.repo_sources=strategy=explicit_map slots=repo_alpha paths=repo_alpha=/tmp/repos/repo-alpha")
    expect(out.string).to include("runtime_summary.distribution=image_ref=a3-engine:a3:v2.1.0 runtime_entrypoint=bin/a3 doctor_entrypoint=bin/a3 doctor-runtime")
    expect(out.string).to include("runtime_summary.execution_modes=one_shot_cli=bin/a3 doctor-runtime ... | bin/a3 migrate-scheduler-store ... | bin/a3 execute-until-idle ... ; scheduler_loop=bin/a3 execute-until-idle ... ; doctor_inspect=bin/a3 doctor-runtime ...")
    expect(out.string).to include("runtime_summary.execution_mode_contract=one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only")
    expect(out.string).to include("runtime_summary.persistent_state_model=scheduler_state_root=/tmp/runtime/state/scheduler task_repository_root=/tmp/runtime/state/tasks run_repository_root=/tmp/runtime/state/runs evidence_root=/tmp/runtime/state/evidence blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses artifact_owner_cache_root=/tmp/runtime/state/artifact_owner_cache logs_root=/tmp/runtime/state/logs workspace_root=/tmp/runtime/state/workspaces artifact_root=/tmp/runtime/state/artifacts")
    expect(out.string).to include("runtime_summary.retention_policy=terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none")
    expect(out.string).to include("runtime_summary.materialization_model=repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start")
    expect(out.string).to include("runtime_summary.runtime_configuration_model=manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required")
    expect(out.string).to include("runtime_summary.deployment_shape=runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project")
    expect(out.string).to include("runtime_summary.networking_boundary=outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project")
    expect(out.string).to include("runtime_summary.upgrade_contract=image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit")
    expect(out.string).to include("runtime_summary.fail_fast_policy=manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast")
    expect(out.string).to include("runtime_summary.credential_boundary_model=secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only")
    expect(out.string).to include("runtime_summary.observability_boundary_model=operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only")
    expect(out.string).to include("distribution_summary.image_ref=a3-engine:a3:v2.1.0")
    expect(out.string).to include("distribution_summary.runtime_entrypoint=bin/a3")
    expect(out.string).to include("distribution_summary.doctor_entrypoint=bin/a3 doctor-runtime")
    expect(out.string).to include("distribution_summary.migration_entrypoint=bin/a3 migrate-scheduler-store")
    expect(out.string).to include("distribution_summary.manifest_schema_version=1")
    expect(out.string).to include("distribution_summary.required_manifest_schema_version=1")
    expect(out.string).to include("distribution_summary.schema_contract=manifest_schema_version=1 required_manifest_schema_version=1")
    expect(out.string).to include("distribution_summary.preset_chain=")
    expect(out.string).to include("distribution_summary.preset_schema_versions=")
    expect(out.string).to include("distribution_summary.required_preset_schema_version=1")
    expect(out.string).to include("distribution_summary.preset_schema_contract=required_preset_schema_version=1 preset_schema_versions=")
    expect(out.string).to include("distribution_summary.secret_delivery_mode=environment_variable")
    expect(out.string).to include("distribution_summary.secret_reference=A3_SECRET")
    expect(out.string).to include("distribution_summary.secret_contract=secret_delivery_mode=environment_variable secret_reference=A3_SECRET")
    expect(out.string).to include("distribution_summary.credential_boundary_model=secret_reference=runtime_package_scoped token_reference=runtime_package_scoped credential_persistence=forbidden_in_workspace secret_injection=external_only")
    expect(out.string).to include("distribution_summary.observability_boundary_model=operator_logs_root=/tmp/runtime/state/logs blocked_diagnosis_root=/tmp/runtime/state/blocked_diagnoses evidence_root=/tmp/runtime/state/evidence canary_output=stdout_only workspace_debug_reference=path_only")
    expect(out.string).to include("distribution_summary.scheduler_store_migration_state=not_required")
    expect(out.string).to include("distribution_summary.migration_contract=scheduler_store_migration_state=not_required")
    expect(out.string).to include("mount_summary.state_root=/tmp/runtime/state")
    expect(out.string).to include("mount_summary.logs_root=/tmp/runtime/state/logs")
    expect(out.string).to include("mount_summary.workspace_root=/tmp/runtime/state/workspaces")
    expect(out.string).to include("mount_summary.artifact_root=/tmp/runtime/state/artifacts")
    expect(out.string).to include("mount_summary.migration_marker_path=/tmp/runtime/state/.a3/scheduler-store-migration.applied")
    expect(out.string).to include("repo_source_strategy=explicit_map")
    expect(out.string).to include("repo_source_slots=repo_alpha")
    expect(out.string).to include("repo_source_paths=repo_alpha=/tmp/repos/repo-alpha")
    expect(out.string).to include("repo_source_details=explicit_map:repo_alpha")
    expect(out.string).to include("runtime_summary.schema_contract=manifest_schema_version=1 required_manifest_schema_version=1")
    expect(out.string).to include("runtime_summary.preset_schema_contract=required_preset_schema_version=1 preset_schema_versions=")
    expect(out.string).to include("runtime_summary.repo_source_contract=repo_source_strategy=explicit_map repo_source_slots=repo_alpha")
    expect(out.string).to include("runtime_summary.secret_contract=secret_delivery_mode=environment_variable secret_reference=A3_SECRET")
    expect(out.string).to include("runtime_summary.migration_contract=scheduler_store_migration_state=not_required")
    expect(out.string).to include("runtime_summary.runtime_contract=manifest_schema_version=1 required_manifest_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=explicit_map repo_source_slots=repo_alpha secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=not_required")
    expect(out.string).to include("runtime_summary.repo_source_action=provide writable repo sources for repo_alpha,repo_beta")
    expect(out.string).to include("runtime_summary.preset_schema_action=no preset schema action required")
    expect(out.string).to include("runtime_summary.secret_delivery_action=provide secrets via environment variable A3_SECRET")
    expect(out.string).to include("runtime_summary.scheduler_store_migration_action=scheduler store migration not required")
    expect(out.string).to include("runtime_summary.startup_checklist=provide writable repo sources for repo_alpha,repo_beta; provide secrets via environment variable A3_SECRET; scheduler store migration not required")
    expect(out.string).to include("runtime_summary.recommended_execution_mode=one_shot_cli")
    expect(out.string).to include("runtime_summary.recommended_execution_mode_reason=runtime contract satisfied; use one_shot_cli to validate execution or start scheduler processing")
    expect(out.string).to include("runtime_summary.recommended_execution_mode_command=bin/a3 doctor-runtime ... && bin/a3 execute-until-idle ...")
    expect(out.string).to include("operator_action=start_continuous_processing")
    expect(out.string).to include("operator_action_command=bin/a3 execute-until-idle ...")
    expect(out.string).to include("next_execution_mode=scheduler_loop")
    expect(out.string).to include("next_execution_mode_reason=runtime canary completed with a ready runtime; continue scheduler loop for ongoing runnable processing")
    expect(out.string).to include("next_execution_mode_command=bin/a3 execute-until-idle ...")
    expect(out.string).to include("runtime_summary.startup_readiness=ready")
    expect(out.string).to include("runtime_summary.operator_guidance=startup ready; runtime package contract satisfied; run bin/a3 execute-until-idle ...")
    expect(out.string).to include("runtime_summary.doctor_command=bin/a3 doctor-runtime ...")
    expect(out.string).to include("runtime_summary.migration_command=bin/a3 migrate-scheduler-store ...")
    expect(out.string).to include("runtime_summary.runtime_command=bin/a3 execute-until-idle ...")
    expect(out.string).to include("runtime_summary.startup_sequence=doctor=bin/a3 doctor-runtime ... migrate=skip runtime=bin/a3 execute-until-idle ...")
    expect(out.string).to include("runtime_summary.runtime_canary_command=bin/a3 doctor-runtime ... && bin/a3 execute-until-idle ...")
    expect(out.string).to include("check.manifest_path=ok path=/tmp/runtime/manifest.yml detail=file exists")
    expect(out.string).to include("migration_status=applied")
    expect(out.string).to include("executed=4")
    expect(out.string).to include("idle=true")
  end

  it "routes manifest project-context commands through the shared manifest session helper" do
    out = StringIO.new
    project_surface = instance_double(A3::Domain::ProjectSurface, resolve: "skills/implementation/base.md")
    merge_config = Struct.new(:target, :policy).new(:merge_to_parent, :ff_only)
    session = Struct.new(:options, :project_surface, :project_context, :container, keyword_init: true).new(
      options: {
        task_kind: :child,
        repo_scope: :repo_alpha,
        phase: :review
      },
      project_surface: project_surface,
      project_context: instance_double(A3::Domain::ProjectContext, merge_config: merge_config, surface: project_surface),
      container: {}
    )
    allow(described_class).to receive(:with_manifest_session).and_yield(session)

    described_class.start(
      ["show-project-context", "/tmp/manifest.yml", "--preset-dir", "/tmp/presets", "--task-kind", "child", "--repo-scope", "repo_alpha", "--phase", "review"],
      out: out
    )

    expect(described_class).to have_received(:with_manifest_session)
    expect(out.string).to include("merge_target=merge_to_parent")
    expect(out.string).to include("implementation_skill=skills/implementation/base.md")
  end

  it "builds manifest sessions through the public bootstrap manifest session API" do
    out = StringIO.new
    project_surface = instance_double(A3::Domain::ProjectSurface, resolve: "skills/implementation/base.md")
    merge_config = Struct.new(:target, :policy).new(:merge_to_parent, :ff_only)
    bootstrap_session = Struct.new(:project_surface, :project_context).new(
      project_surface,
      instance_double(A3::Domain::ProjectContext, merge_config: merge_config, surface: project_surface)
    )
    allow(A3::Bootstrap).to receive(:manifest_session).and_return(bootstrap_session)

    described_class.start(
      ["show-project-context", "/tmp/manifest.yml", "--preset-dir", "/tmp/presets", "--task-kind", "child", "--repo-scope", "repo_alpha", "--phase", "review"],
      out: out
    )

    expect(A3::Bootstrap).to have_received(:manifest_session).with(
      manifest_path: "/tmp/manifest.yml",
      preset_dir: "/tmp/presets"
    )
    expect(out.string).to include("merge_target=merge_to_parent")
  end

  it "starts a run and persists it through JSON repositories" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          parent_ref: "A3-v2#3022"
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "start-run",
          "A3-v2#3025",
          "implementation",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--source-type", "branch_head",
          "--source-ref", "refs/heads/a3/work/A3-v2-3025",
          "--bootstrap-marker", "workspace-hook:v1",
          "--review-base", "base123",
          "--review-head", "head456"
        ],
        out: out,
        run_id_generator: -> { "run-1" }
      )

      persisted_task = task_repository.fetch("A3-v2#3025")
      persisted_run = run_repository.fetch("run-1")

      expect(out.string).to include("started run run-1")
      expect(persisted_task.current_run_ref).to eq("run-1")
      expect(persisted_task.status).to eq(:in_progress)
      expect(persisted_run.phase).to eq(:implementation)
      expect(persisted_run.artifact_owner.snapshot_version).to eq("head456")
    end
  end

  it "completes a run and updates task lifecycle through JSON repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      run_repository = A3::Infra::JsonRunRepository.new(File.join(dir, "runs.json"))

      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          status: :in_progress,
          current_run_ref: "run-1",
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-1",
          task_ref: "A3-v2#3025",
          phase: :implementation,
          workspace_kind: :ticket_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :ticket_workspace,
            source_type: :branch_head,
            ref: "refs/heads/a3/work/A3-v2-3025",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "complete-run",
          "A3-v2#3025",
          "run-1",
          "completed",
          "--storage-dir", dir
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      persisted_task = task_repository.fetch("A3-v2#3025")
      persisted_run = run_repository.fetch("run-1")

      expect(out.string).to include("completed run run-1")
      expect(persisted_task.status).to eq(:verifying)
      expect(persisted_task.current_run_ref).to be_nil
      expect(persisted_run.terminal_outcome).to eq(:completed)
    end
  end

  it "starts a run through sqlite repositories when sqlite backend is selected" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          parent_ref: "A3-v2#3022"
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "start-run",
          "A3-v2#3025",
          "implementation",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          *repo_source_args(repo_sources),
          "--source-type", "branch_head",
          "--source-ref", "refs/heads/a3/work/A3-v2-3025",
          "--bootstrap-marker", "workspace-hook:v1",
          "--review-base", "base123",
          "--review-head", "head456"
        ],
        out: out,
        run_id_generator: -> { "run-sqlite-1" }
      )

      persisted_task = task_repository.fetch("A3-v2#3025")
      persisted_run = run_repository.fetch("run-sqlite-1")

      expect(out.string).to include("started run run-sqlite-1")
      expect(persisted_task.current_run_ref).to eq("run-sqlite-1")
      expect(persisted_run.phase).to eq(:implementation)
    end
  end

  it "fails fast when start-run omits bootstrap marker" do
    Dir.mktmpdir do |dir|
      repo_sources = create_repo_sources(dir)
      task_repository = A3::Infra::JsonTaskRepository.new(File.join(dir, "tasks.json"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha]
        )
      )

      expect do
        described_class.start(
          [
            "start-run",
            "A3-v2#3025",
            "implementation",
            "--storage-dir", dir,
            *repo_source_args(repo_sources),
            "--source-type", "branch_head",
            "--source-ref", "refs/heads/a3/work/A3-v2-3025",
            "--review-base", "base123",
            "--review-head", "head456"
          ],
          out: StringIO.new,
          run_id_generator: -> { "run-missing-marker" }
        )
      end.to raise_error(KeyError)
    end
  end

  it "prints rerun planning through sqlite repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-rerun-1",
          task_ref: "A3-v2#3025",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "plan-rerun",
          "A3-v2#3025",
          "run-rerun-1",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--source-type", "detached_commit",
          "--source-ref", "head456",
          "--review-base", "base123",
          "--review-head", "head456",
          "--snapshot-version", "head456"
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      expect(out.string).to include("rerun decision same_phase_retry")
      expect(out.string).to include("operator_action_required=false")
    end
  end

  it "prints actionable persisted rerun recovery through sqlite repositories" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "schema_version: 1\npresets: []\n")
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-recovery-1",
          task_ref: "A3-v2#3025",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          )
        )
      )

      out = StringIO.new
      described_class.start(
        [
          "recover-rerun",
          "A3-v2#3025",
          "run-recovery-1",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--preset-dir", preset_dir,
          "--source-type", "detached_commit",
          "--source-ref", "head456",
          "--review-base", "base123",
          "--review-head", "head456",
          "--snapshot-version", "head456",
          manifest_path
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      expect(out.string).to include("rerun recovery same_phase_retry")
      expect(out.string).to include("action=retry_current_phase")
      expect(out.string).to include("target_phase=review")
      expect(out.string).to include("runtime_package_next_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_guidance=startup blocked by secret_delivery; provide secrets via environment variable A3_SECRET; run bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_contract_health=manifest_schema=ok preset_schema=ok repo_sources=ok secret_delivery=missing scheduler_store_migration=ok")
      expect(out.string).to include("runtime_package_execution_modes=one_shot_cli=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} | bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} | bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} ; scheduler_loop=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} ; doctor_inspect=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_execution_mode_contract=one_shot_cli=operator_driven_doctor_migration_runtime ; scheduler_loop=continuous_runnable_processing_after_runtime_ready ; doctor_inspect=configuration_and_mount_validation_only")
      expect(out.string).to include("runtime_package_schema_action=update runtime package manifest schema to 1")
      expect(out.string).to include("runtime_package_preset_schema_action=no preset schema action required")
      expect(out.string).to include("runtime_package_repo_source_action=no repo source action required")
      expect(out.string).to include("runtime_package_secret_delivery_action=provide secrets via environment variable A3_SECRET")
      expect(out.string).to include("runtime_package_scheduler_store_migration_action=scheduler store migration not required")
      expect(out.string).to include("runtime_package_recommended_execution_mode=doctor_inspect")
      expect(out.string).to include("runtime_package_recommended_execution_mode_reason=runtime is not ready; use doctor_inspect until blockers are resolved")
      expect(out.string).to include("runtime_package_recommended_execution_mode_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_migration_command=bin/a3 migrate-scheduler-store #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_doctor_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_runtime_command=bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_runtime_canary_command=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir}")
      expect(out.string).to include("runtime_package_startup_sequence=doctor=bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend sqlite --storage-dir #{dir} migrate=blocked runtime=blocked")
      expect(out.string).to include("runtime_package_startup_blockers=secret_delivery")
      expect(out.string).to include("runtime_package_persistent_state_model=scheduler_state_root=#{File.join(dir, 'scheduler')} task_repository_root=#{File.join(dir, 'tasks')} run_repository_root=#{File.join(dir, 'runs')} evidence_root=#{File.join(dir, 'evidence')} blocked_diagnosis_root=#{File.join(dir, 'blocked_diagnoses')} artifact_owner_cache_root=#{File.join(dir, 'artifact_owner_cache')} logs_root=#{File.join(dir, 'logs')} workspace_root=#{File.join(dir, 'workspaces')} artifact_root=#{File.join(dir, 'artifacts')}")
      expect(out.string).to include("runtime_package_retention_policy=terminal_workspace_cleanup=retention_policy_controlled blocked_evidence_retention=independent_from_scheduler_cleanup image_upgrade_cleanup_trigger=none")
      expect(out.string).to include("runtime_package_materialization_model=repo_slot_namespace=task_workspace_fixed implementation_workspace=ticket_workspace review_workspace=runtime_workspace verification_workspace=runtime_workspace merge_workspace=runtime_workspace missing_repo_rescue=forbidden source_descriptor_alignment=required_before_phase_start")
      expect(out.string).to include("runtime_package_runtime_configuration_model=manifest_path=required preset_dir=required storage_backend=required state_root=required workspace_root=required artifact_root=required repo_source_strategy=required repository_metadata=required authoritative_branch_resolution=required integration_target_resolution=required secret_reference=required")
      expect(out.string).to include("runtime_package_observability_boundary_model=operator_logs_root=#{File.join(dir, 'logs')} blocked_diagnosis_root=#{File.join(dir, 'blocked_diagnoses')} evidence_root=#{File.join(dir, 'evidence')} canary_output=stdout_only workspace_debug_reference=path_only")
      expect(out.string).to include("runtime_package_deployment_shape=runtime_package=single_project writable_state=isolated scheduler_instance=single_project state_boundary=project secret_boundary=project")
      expect(out.string).to include("runtime_package_networking_boundary=outbound=git,issue_api,package_registry,llm_gateway,verification_service secret_source=secret_store token_scope=project")
      expect(out.string).to include("runtime_package_upgrade_contract=image_upgrade=independent manifest_schema_version=1 preset_schema_version=1 state_migration=explicit")
      expect(out.string).to include("runtime_package_fail_fast_policy=manifest_schema_mismatch=fail_fast preset_schema_conflict=fail_fast writable_mount_missing=fail_fast secret_missing=fail_fast scheduler_store_migration_pending=fail_fast")
    end
  end

  it "prints blocked diagnosis through sqlite repositories" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          status: :blocked,
          parent_ref: "A3-v2#3022"
        )
      )
      run_repository.save(
        A3::Domain::Run.new(
          ref: "run-blocked-1",
          task_ref: "A3-v2#3025",
          phase: :review,
          workspace_kind: :runtime_workspace,
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          ),
          terminal_outcome: :blocked
        )
      )

      out = StringIO.new

      described_class.start(
        [
          "diagnose-blocked",
          "A3-v2#3025",
          "run-blocked-1",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--expected-state", "runtime workspace available",
          "--observed-state", "repo-beta missing",
          "--failing-command", "codex exec --json -",
          "--diagnostic-summary", "review launch could not resolve runtime workspace",
          "--infra-diagnostic", "missing_path=/tmp/repo-beta",
          "--infra-diagnostic", "exception=Errno::ENOENT"
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      expect(out.string).to include("blocked diagnosis blocked")
      expect(out.string).to include("repo-beta missing")
      persisted = run_repository.fetch("run-blocked-1").phase_records.last.blocked_diagnosis
      expect(persisted.infra_diagnostics).to eq(
        "missing_path" => "/tmp/repo-beta",
        "exception" => "Errno::ENOENT"
      )
    end
  end

  it "prints persisted blocked diagnosis and evidence summary through sqlite repositories" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "manifest.yml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "presets: []\n")
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      run_repository = A3::Infra::SqliteRunRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3025",
          kind: :child,
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          status: :blocked,
          parent_ref: "A3-v2#3022"
        )
      )

      run = A3::Domain::Run.new(
        ref: "run-blocked-2",
        task_ref: "A3-v2#3025",
        phase: :review,
        workspace_kind: :runtime_workspace,
        source_descriptor: A3::Domain::SourceDescriptor.new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: "head456",
          task_ref: "A3-v2#3025"
        ),
        scope_snapshot: A3::Domain::ScopeSnapshot.new(
          edit_scope: [:repo_alpha],
          verification_scope: [:repo_alpha, :repo_beta],
          ownership_scope: :task
        ),
        review_target: A3::Domain::ReviewTarget.new(
          base_commit: "base123",
          head_commit: "head456",
          task_ref: "A3-v2#3025",
          phase_ref: :review
        ),
        artifact_owner: A3::Domain::ArtifactOwner.new(
          owner_ref: "A3-v2#3022",
          owner_scope: :task,
          snapshot_version: "head456"
        ),
        terminal_outcome: :blocked
      ).append_blocked_diagnosis(
        A3::Domain::BlockedDiagnosis.new(
          task_ref: "A3-v2#3025",
          run_ref: "run-blocked-2",
          phase: :review,
          outcome: :blocked,
          review_target: A3::Domain::ReviewTarget.new(
            base_commit: "base123",
            head_commit: "head456",
            task_ref: "A3-v2#3025",
            phase_ref: :review
          ),
          source_descriptor: A3::Domain::SourceDescriptor.new(
            workspace_kind: :runtime_workspace,
            source_type: :detached_commit,
            ref: "head456",
            task_ref: "A3-v2#3025"
          ),
          scope_snapshot: A3::Domain::ScopeSnapshot.new(
            edit_scope: [:repo_alpha],
            verification_scope: [:repo_alpha, :repo_beta],
            ownership_scope: :task
          ),
          artifact_owner: A3::Domain::ArtifactOwner.new(
            owner_ref: "A3-v2#3022",
            owner_scope: :task,
            snapshot_version: "head456"
          ),
          expected_state: "runtime workspace available",
          observed_state: "repo-beta missing",
          failing_command: "codex exec --json -",
          diagnostic_summary: "review launch could not resolve runtime workspace",
          infra_diagnostics: { "missing_path" => "/tmp/repo-beta" }
        ),
        execution_record: A3::Domain::PhaseExecutionRecord.new(
          summary: "review launch could not resolve runtime workspace",
          failing_command: "codex exec --json -",
          observed_state: "repo-beta missing",
          diagnostics: {
            "missing_path" => "/tmp/repo-beta",
            "worker_response_bundle" => {
              "success" => false,
              "summary" => "review blocked",
              "failing_command" => "codex exec --json -",
              "observed_state" => "repo-beta missing"
            }
          },
          runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.new(
            task_kind: :child,
            repo_scope: :repo_alpha,
            phase: :review,
            implementation_skill: "sample-implementation",
            review_skill: "sample-review",
            verification_commands: ["commands/check-style", "commands/verify-all"],
            remediation_commands: ["commands/apply-remediation"],
            workspace_hook: "sample-bootstrap",
            merge_target: :merge_to_parent,
            merge_policy: :ff_only
          )
        )
      )
      run_repository.save(run)

      out = StringIO.new

      described_class.start(
        [
          "show-blocked-diagnosis",
          "A3-v2#3025",
          "run-blocked-2",
          "--storage-backend", "sqlite",
          "--storage-dir", dir,
          "--preset-dir", preset_dir,
          manifest_path
        ],
        out: out,
        run_id_generator: -> { "unused" }
      )

      expect(out.string).to include("blocked diagnosis blocked for run-blocked-2 on A3-v2#3025")
      expect(out.string).to include("phase=verification observed=repo-beta missing")
      expect(out.string).to include("recovery decision=requires_operator_action next_action=diagnose_blocked operator_action_required=true")
      expect(out.string).to include("rerun_hint=diagnose blocked state and choose a fresh rerun source")
      expect(out.string).to include("review_target=base123..head456")
      expect(out.string).to include("edit_scope=repo_alpha")
      expect(out.string).to include("verification_scope=repo_alpha,repo_beta")
      expect(out.string).to include("diagnostic.missing_path=/tmp/repo-beta")
    end
  end
end
