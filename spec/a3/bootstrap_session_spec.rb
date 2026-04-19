# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Bootstrap do
  it "assembles a project config session without storage dependencies" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = write_runtime_package(dir, manifest_path)

      session = described_class.manifest_session(
        manifest_path: manifest_path,
        preset_dir: preset_dir
      )

      expect(session).to be_frozen
      expect(session.project_surface.implementation_skill).to eq("skills/implementation/base.md")
      expect(session.project_context.merge_config.target).to eq(:merge_to_parent)
      expect(session.project_context.merge_config.policy).to eq(:ff_only)
    end
  end

  it "assembles a project config driven session with project context and storage container" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = write_runtime_package(dir, manifest_path)

      session = described_class.session(
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: {},
        run_id_generator: -> { "run-1" }
      )

      expect(session).to be_frozen
      expected_surface = described_class.project_surface(manifest_path: manifest_path, preset_dir: preset_dir)
      expected_context = described_class.project_context(manifest_path: manifest_path, preset_dir: preset_dir)
      expect(session.project_surface.implementation_skill).to eq(expected_surface.implementation_skill)
      expect(session.project_surface.review_skill).to eq(expected_surface.review_skill)
      expect(session.project_surface.verification_commands).to eq(expected_surface.verification_commands)
      expect(session.project_surface.remediation_commands).to eq(expected_surface.remediation_commands)
      expect(session.project_surface.workspace_hook).to eq(expected_surface.workspace_hook)
      expect(session.project_context.surface.implementation_skill).to eq(expected_context.surface.implementation_skill)
      expect(session.project_context.surface.review_skill).to eq(expected_context.surface.review_skill)
      expect(session.project_context.surface.verification_commands).to eq(expected_context.surface.verification_commands)
      expect(session.project_context.surface.remediation_commands).to eq(expected_context.surface.remediation_commands)
      expect(session.project_context.surface.workspace_hook).to eq(expected_context.surface.workspace_hook)
      expect(session.project_context.merge_config.target).to eq(expected_context.merge_config.target)
      expect(session.project_context.merge_config.policy).to eq(expected_context.merge_config.policy)
      expect(session.runtime_package).to eq(
        described_class.runtime_package_descriptor(
          manifest_path: manifest_path,
          preset_dir: preset_dir,
          storage_backend: :json,
          storage_dir: dir,
          repo_sources: {}
        )
      )
      expect(session.runtime_environment_config.runtime_package).to be(session.runtime_package)
      expect(session.runtime_environment_config.container).to be(session.container)
      expect(session.container).to include(:task_repository, :run_repository, :scheduler_state_repository, :scheduler_cycle_repository)
      expect(session.storage_backend).to eq(:json)
      expect(session.manifest_path).to eq(manifest_path)
    end
  end

  it "assembles a project config driven sqlite session through the shared session assembly path" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = write_runtime_package(dir, manifest_path)

      session = A3::Bootstrap::Session.build(
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :sqlite,
        storage_dir: dir,
        repo_sources: {},
        run_id_generator: -> { "run-1" }
      )

      expect(session.storage_backend).to eq(:sqlite)
      expect(session.runtime_environment_config.runtime_package).to eq(session.runtime_package)
      expect(session.container.fetch(:task_repository)).to be_a(A3::Infra::SqliteTaskRepository)
      expect(session.container.fetch(:run_repository)).to be_a(A3::Infra::SqliteRunRepository)
      expect(session.container.fetch(:show_scheduler_state).call.paused).to eq(false)
      expect(session.container.fetch(:pause_scheduler).call.paused).to eq(true)
      expect(session.container.fetch(:show_scheduler_state).call.paused).to eq(true)
      expect(session.container.fetch(:resume_scheduler).call.paused).to eq(false)
      expect(session.container.fetch(:show_scheduler_state).call.paused).to eq(false)
    end
  end



  it "exposes a runtime package descriptor on project config driven sessions" do
    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, "project.yaml")
      preset_dir = write_runtime_package(dir, manifest_path)

      session = described_class.session(
        manifest_path: manifest_path,
        preset_dir: preset_dir,
        storage_backend: :json,
        storage_dir: dir,
        repo_sources: {repo_alpha: File.join(dir, 'repo-alpha')},
        run_id_generator: -> { 'run-1' }
      )

      expect(session.runtime_package.image_version).to eq('dev')
      expect(session.runtime_package.manifest_path).to eq(Pathname(manifest_path))
      expect(session.runtime_package.project_runtime_root).to eq(Pathname(dir))
      expect(session.runtime_package.storage_dir).to eq(Pathname(dir))
      expect(session.runtime_package.workspace_root).to eq(Pathname(dir).join('workspaces'))
      expect(session.runtime_package.artifact_root).to eq(Pathname(dir).join('artifacts'))
      expect(session.runtime_package.repo_source_strategy).to eq(:explicit_map)
      expect(session.runtime_package.repo_source_slots).to eq([:repo_alpha])
    end
  end

  it "raises for unsupported storage backends" do
    expect do
      described_class.session(
        manifest_path: "project.yaml",
        preset_dir: "presets",
        storage_backend: :unknown,
        storage_dir: "/tmp",
        repo_sources: {},
        run_id_generator: -> { "run-1" }
      )
    end.to raise_error(ArgumentError, /unsupported storage backend/)
  end

  def write_runtime_package(dir, manifest_path)
    preset_dir = File.join(dir, "presets")
    FileUtils.mkdir_p(preset_dir)
    File.write(
      manifest_path,
      YAML.dump(
        {
          "schema_version" => 1,
          "runtime" => {
            "phases" => {
              "implementation" => {
                "skill" => "skills/implementation/base.md"
              },
              "review" => {
                "skill" => "skills/review/default.md"
              },
              "verification" => {
                "commands" => ["commands/verify-all"]
              },
              "remediation" => {
                "commands" => ["commands/apply-remediation"]
              },
              "merge" => {
                "target" => "merge_to_parent",
                "policy" => "ff_only",
                "target_ref" => "refs/heads/live"
              }
            }
          }
        }
      )
    )
    preset_dir
  end
end
