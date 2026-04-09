# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::Adapters::ProjectContextLoader do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      @preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(@preset_dir)
      example.run
    end
  end

  let(:loader) { described_class.new(preset_dir: @preset_dir) }

  before do
    File.write(
      File.join(@preset_dir, "base.yml"),
      YAML.dump(
        {
          "schema_version" => "1",
          "implementation_skill" => "skills/implementation/base.md",
          "review_skill" => "skills/review/base.md",
          "verification_commands" => ["commands/verify-all"],
          "remediation_commands" => ["commands/apply-remediation"],
          "workspace_hook" => "hooks/prepare-runtime.sh"
        }
      )
    )
  end

  it "loads project surface and core merge config together" do
    manifest_path = write_manifest(
      {
        "presets" => ["base"],
        "core" => {
          "merge_target" => "merge_to_parent",
          "merge_policy" => "ff_only",
          "merge_target_ref" => "refs/heads/feature/prototype"
        }
      }
    )

    context = loader.load(manifest_path)

    expect(context.surface.implementation_skill).to eq("skills/implementation/base.md")
    expect(context.merge_config.target).to eq(:merge_to_parent)
    expect(context.merge_config.policy).to eq(:ff_only)
    expect(context.merge_config.target_ref).to eq("refs/heads/feature/prototype")
  end

  it "rejects unknown merge target" do
    manifest_path = write_manifest(
      {
        "presets" => ["base"],
        "core" => {
          "merge_target" => "invented_target",
          "merge_policy" => "ff_only",
          "merge_target_ref" => "refs/heads/feature/prototype"
        }
      }
    )

    expect { loader.load(manifest_path) }.to raise_error(A3::Domain::ConfigurationError)
  end

  it "rejects missing core merge config" do
    manifest_path = write_manifest(
      {
        "presets" => ["base"]
      }
    )

    expect { loader.load(manifest_path) }
      .to raise_error(A3::Domain::ConfigurationError, "manifest core.merge_target and core.merge_policy must be provided")
  end

  it "rejects missing core merge target ref" do
    manifest_path = write_manifest(
      {
        "presets" => ["base"],
        "core" => {
          "merge_target" => "merge_to_parent",
          "merge_policy" => "ff_only"
        }
      }
    )

    expect { loader.load(manifest_path) }
      .to raise_error(A3::Domain::ConfigurationError, "manifest core.merge_target_ref must be provided")
  end

  it "rejects blank core merge target ref" do
    manifest_path = write_manifest(
      {
        "presets" => ["base"],
        "core" => {
          "merge_target" => "merge_to_parent",
          "merge_policy" => "ff_only",
          "merge_target_ref" => "   "
        }
      }
    )

    expect { loader.load(manifest_path) }
      .to raise_error(A3::Domain::ConfigurationError, "manifest core.merge_target_ref must not be blank")
  end

  it "loads task-kind-specific merge config variants" do
    manifest_path = write_manifest(
      {
        "presets" => ["base"],
        "core" => {
          "merge_target" => {
            "default" => "merge_to_live",
            "variants" => {
              "task_kind" => {
                "child" => {"default" => "merge_to_parent"},
                "parent" => {"default" => "merge_to_live"}
              }
            }
          },
          "merge_target_ref" => {
            "default" => "refs/heads/live",
            "variants" => {
              "task_kind" => {
                "parent" => {"default" => "refs/heads/feature/prototype"}
              }
            }
          },
          "merge_policy" => "ff_only"
        }
      }
    )

    context = loader.load(manifest_path)
    child_task = A3::Domain::Task.new(
      ref: "A3-v2#3037",
      kind: :child,
      edit_scope: [:repo_beta],
      parent_ref: "A3-v2#3036"
    )
    parent_task = A3::Domain::Task.new(
      ref: "A3-v2#3036",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      child_refs: %w[A3-v2#3037 A3-v2#3038]
    )

    expect(context.merge_config.target).to eq(:merge_to_live)
    expect(context.merge_config.target_ref).to eq("refs/heads/live")
    expect(context.merge_config_for(task: child_task, phase: :merge).target).to eq(:merge_to_parent)
    expect(context.merge_config_for(task: child_task, phase: :merge).target_ref).to eq("refs/heads/live")
    expect(context.merge_config_for(task: parent_task, phase: :merge).target).to eq(:merge_to_live)
    expect(context.merge_config_for(task: parent_task, phase: :merge).target_ref).to eq("refs/heads/feature/prototype")
  end

  private

  def write_manifest(payload)
    path = File.join(@tmpdir, "manifest.yml")
    File.write(path, YAML.dump(payload))
    path
  end
end
