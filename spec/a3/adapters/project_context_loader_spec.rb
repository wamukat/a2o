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
    project_config_path = write_project_config(
      {
        "runtime" => {
          "presets" => ["base"],
          "merge" => {
            "target" => "merge_to_parent",
            "policy" => "ff_only",
            "target_ref" => "refs/heads/feature/prototype"
          }
        }
      }
    )

    context = loader.load(project_config_path)

    expect(context.surface.implementation_skill).to eq("skills/implementation/base.md")
    expect(context.merge_config.target).to eq(:merge_to_parent)
    expect(context.merge_config.policy).to eq(:ff_only)
    expect(context.merge_config.target_ref).to eq("refs/heads/feature/prototype")
  end

  it "rejects unknown merge target" do
    project_config_path = write_project_config(
      {
        "runtime" => {
          "presets" => ["base"],
          "merge" => {
            "target" => "invented_target",
            "policy" => "ff_only",
            "target_ref" => "refs/heads/feature/prototype"
          }
        }
      }
    )

    expect { loader.load(project_config_path) }.to raise_error(A3::Domain::ConfigurationError)
  end

  it "rejects missing core merge config" do
    project_config_path = write_project_config(
      {
        "runtime" => {
          "presets" => ["base"]
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.merge.target and runtime.merge.policy must be provided")
  end

  it "rejects missing core merge target ref" do
    project_config_path = write_project_config(
      {
        "runtime" => {
          "presets" => ["base"],
          "merge" => {
            "target" => "merge_to_parent",
            "policy" => "ff_only"
          }
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.merge.target_ref must be provided")
  end

  it "rejects blank core merge target ref" do
    project_config_path = write_project_config(
      {
        "runtime" => {
          "presets" => ["base"],
          "merge" => {
            "target" => "merge_to_parent",
            "policy" => "ff_only",
            "target_ref" => "   "
          }
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.merge.target_ref must not be blank")
  end

  it "loads task-kind-specific merge config variants" do
    project_config_path = write_project_config(
      {
        "runtime" => {
          "presets" => ["base"],
          "merge" => {
            "target" => {
              "default" => "merge_to_live",
              "variants" => {
                "task_kind" => {
                  "child" => {"default" => "merge_to_parent"},
                  "parent" => {"default" => "merge_to_live"}
                }
              }
            },
            "target_ref" => {
              "default" => "refs/heads/live",
              "variants" => {
                "task_kind" => {
                  "parent" => {"default" => "refs/heads/feature/prototype"}
                }
              }
            },
            "policy" => "ff_only"
          }
        }
      }
    )

    context = loader.load(project_config_path)
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

  it "rejects legacy manifest.yml paths" do
    project_config_path = File.join(@tmpdir, "manifest.yml")
    File.write(project_config_path, YAML.dump({ "schema_version" => 1, "runtime" => { "presets" => [] } }))

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "manifest.yml is no longer supported; use project.yaml")
  end

  private

  def write_project_config(payload)
    path = File.join(@tmpdir, "project.yaml")
    File.write(path, YAML.dump({ "schema_version" => 1 }.merge(payload)))
    path
  end
end
