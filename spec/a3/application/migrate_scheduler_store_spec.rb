# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Application::MigrateSchedulerStore do
  it "writes a migration marker when scheduler store migration is pending" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "schema_version: 1\nruntime:\n  presets: []\n")
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

      expect(result.status).to eq(:applied)
      expect(result.migration_state).to eq(:applied)
      expect(result.marker_path).to eq(runtime_package.migration_marker_path)
      expect(result.marker_path.file?).to be(true)
    end
  end

  it "is a no-op when migration is not required" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(preset_dir)
      File.write(manifest_path, "schema_version: 1\nruntime:\n  presets: []\n")
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
        scheduler_store_migration_state: :not_required
      )

      result = described_class.new(runtime_package: runtime_package).call

      expect(result.status).to eq(:not_required)
      expect(result.marker_path.file?).to be(false)
    end
  end
end
