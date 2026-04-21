# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Bootstrap do
  describe ".container" do
    it "assembles a backend-selected container through a single public bootstrap entrypoint" do
      Dir.mktmpdir do |dir|
        container = described_class.container(
          storage_backend: :sqlite,
          storage_dir: dir,
          repo_sources: {},
          run_id_generator: -> { "run-1" }
        )

        expect(container.fetch(:task_repository)).to be_a(A3::Infra::SqliteTaskRepository)
        expect(container.fetch(:run_repository)).to be_a(A3::Infra::SqliteRunRepository)
        expect(container.fetch(:scheduler_state_repository)).to be_a(A3::Infra::SqliteSchedulerStateRepository)
      end
    end
  end

  describe ".json_container" do
    it "assembles repositories, runtime services, and scheduler services" do
      Dir.mktmpdir do |dir|
        container = described_class.json_container(
          storage_dir: dir,
          repo_sources: {},
          run_id_generator: -> { "run-1" }
        )

        expect(container).to include(
          :task_repository,
          :run_repository,
          :scheduler_state_repository,
          :scheduler_cycle_repository,
          :start_run,
          :schedule_next_run,
          :execute_next_runnable_task,
          :execute_until_idle
        )
      end
    end
  end

  describe ".runtime_package_session" do
    it "assembles a runtime package descriptor without project surface or container assembly" do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "project.yaml")
        preset_dir = File.join(dir, "presets")
        FileUtils.mkdir_p(preset_dir)
        File.write(manifest_path, YAML.dump({ "schema_version" => 1, "runtime" => { "presets" => [] } }))
        session = described_class.runtime_package_session(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :sqlite,
          storage_dir: dir,
          repo_sources: { repo_alpha: File.join(dir, "repos", "repo-alpha") }
        )

        expect(session).to be_frozen
        expect(session.runtime_package).to be_a(A3::Domain::RuntimePackageDescriptor)
        expect(session.runtime_package.operator_summary.fetch("mount")).to include("state_root=#{dir}")
        expect(session.runtime_package.repo_source_summary.fetch("strategy")).to eq(:explicit_map)
        expect(session.runtime_package.operator_summary.fetch("distribution")).to eq("image_ref=a3-engine:dev runtime_entrypoint=bin/a3 doctor_entrypoint=bin/a3 doctor-runtime")
        expect(session.runtime_package.operator_summary.fetch("schema_contract")).to eq("project_config_schema_version=1 required_project_config_schema_version=1")
        expect(session.runtime_package.operator_summary.fetch("preset_schema_contract")).to eq("required_preset_schema_version=1 preset_schema_versions=")
        expect(session.runtime_package.operator_summary.fetch("repo_source_contract")).to eq("repo_source_strategy=explicit_map repo_source_slots=repo_alpha")
        expect(session.runtime_package.operator_summary.fetch("repo_source_action")).to eq("provide writable repo sources for repo_alpha")
        expect(session.runtime_package.operator_summary.fetch("preset_schema_action")).to eq("no preset schema action required")
        expect(session.runtime_package.operator_summary.fetch("secret_contract")).to eq("secret_delivery_mode=environment_variable secret_reference=A3_SECRET")
        expect(session.runtime_package.operator_summary.fetch("migration_contract")).to eq("scheduler_store_migration_state=not_required")
        expect(session.runtime_package.operator_summary.fetch("runtime_contract")).to eq("project_config_schema_version=1 required_project_config_schema_version=1 required_preset_schema_version=1 preset_schema_versions= repo_source_strategy=explicit_map repo_source_slots=repo_alpha secret_delivery_mode=environment_variable secret_reference=A3_SECRET scheduler_store_migration_state=not_required")
        expect(session.runtime_package.operator_summary.fetch("secret_delivery_action")).to eq("provide secrets via environment variable A3_SECRET")
        expect(session.runtime_package.operator_summary.fetch("scheduler_store_migration_action")).to eq("scheduler store migration not required")
        expect(session.runtime_package.operator_summary.fetch("startup_checklist")).to eq("provide writable repo sources for repo_alpha; provide secrets via environment variable A3_SECRET; scheduler store migration not required")
        expect(session.runtime_package.operator_summary.fetch("descriptor_startup_readiness")).to eq("descriptor_ready")
        expect(session.runtime_package.operator_summary.fetch("operator_action")).to eq("provide writable repo sources for repo_alpha; provide secrets via environment variable A3_SECRET; scheduler store migration not required")
      end
    end

    it "prefers the public A2O image version environment for runtime package descriptors" do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "project.yaml")
        preset_dir = File.join(dir, "presets")
        FileUtils.mkdir_p(preset_dir)
        File.write(manifest_path, YAML.dump({ "schema_version" => 1, "runtime" => { "presets" => [] } }))

        with_env("A2O_IMAGE_VERSION" => "0.5.7", "A3_IMAGE_VERSION" => "legacy") do
          descriptor = described_class.runtime_package_descriptor(
            manifest_path: manifest_path,
            preset_dir: preset_dir,
            storage_backend: :sqlite,
            storage_dir: dir,
            repo_sources: {}
          )

          expect(descriptor.image_version).to eq("0.5.7")
          expect(descriptor.operator_summary.fetch("distribution")).to include("image_ref=a3-engine:0.5.7")
        end
      end
    end

    it "rejects legacy manifest.yml runtime package paths" do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "manifest.yml")
        preset_dir = File.join(dir, "presets")
        FileUtils.mkdir_p(preset_dir)
        File.write(manifest_path, YAML.dump({ "schema_version" => 1, "runtime" => { "presets" => [] } }))

        expect do
          described_class.runtime_package_session(
            manifest_path: manifest_path,
            preset_dir: preset_dir,
            storage_backend: :sqlite,
            storage_dir: dir,
            repo_sources: {}
          )
        end.to raise_error(A3::Domain::ConfigurationError, "manifest.yml is no longer supported; use project.yaml")
      end
    end
  end
end
