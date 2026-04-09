# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::RunRuntimeCanary do
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

  let(:execute_until_idle) do
    instance_double(
      A3::Application::ExecuteUntilIdle,
      call: Struct.new(:executed_count, :idle_reached, :stop_reason, :quarantined_count).new(3, true, :idle, 1)
    )
  end

  it "migrates pending scheduler store and then executes until idle" do
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

      result = described_class.new(
        runtime_package: runtime_package,
        execute_until_idle: execute_until_idle
      ).call(project_context: Object.new, max_steps: 5)

      expect(result.status).to eq(:completed)
      expect(result.migration_result).to have_attributes(status: :applied)
      expect(result.doctor_result.startup_readiness).to eq(:ready)
      expect(result.scheduler_result.executed_count).to eq(3)
      expect(result.operator_action).to eq(:start_continuous_processing)
      expect(result.operator_action_command).to eq("bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.next_execution_mode).to eq(:scheduler_loop)
      expect(result.next_execution_mode_reason).to eq("runtime canary completed with a ready runtime; continue scheduler loop for ongoing runnable processing")
      expect(result.next_execution_mode_command).to eq("bin/a3 execute-until-idle #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      end
    end
  end

  it "stops before execution when startup is still invalid" do
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
        repo_sources: { repo_alpha: File.join(dir, "missing") },
        manifest_schema_version: "1",
        required_manifest_schema_version: "1",
        preset_chain: [],
        preset_schema_versions: {},
        required_preset_schema_version: "1",
        secret_reference: "A3_SECRET"
      )

      result = described_class.new(
        runtime_package: runtime_package,
        execute_until_idle: execute_until_idle
      ).call(project_context: Object.new, max_steps: 5)

      expect(result.status).to eq(:blocked)
      expect(result.scheduler_result).to be_nil
      expect(result.doctor_result.startup_blockers).to include("repo_sources")
      expect(result.operator_action).to eq(:keep_inspecting)
      expect(result.operator_action_command).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
      expect(result.next_execution_mode).to eq(:doctor_inspect)
      expect(result.next_execution_mode_reason).to eq("runtime canary is blocked; continue doctor/inspection until startup blockers are resolved")
      expect(result.next_execution_mode_command).to eq("bin/a3 doctor-runtime #{manifest_path} --preset-dir #{preset_dir} --storage-backend json --storage-dir #{dir}")
    end
  end
end
