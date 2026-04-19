# frozen_string_literal: true

require "tmpdir"
require "yaml"

RSpec.describe A3::Adapters::ProjectSurfaceLoader do
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      @preset_dir = File.join(dir, "presets")
      FileUtils.mkdir_p(@preset_dir)
      example.run
    end
  end

  let(:loader) { described_class.new(preset_dir: @preset_dir) }

  it "loads project surface from runtime phases" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md",
            "workspace_hook" => "hooks/prepare-runtime.sh"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          },
          "verification" => {
            "commands" => ["commands/verify-all"]
          },
          "remediation" => {
            "commands" => ["commands/apply-remediation"]
          }
        }
      }
    )

    surface = loader.load(project_config_path)

    expect(surface.implementation_skill).to eq("skills/implementation/base.md")
    expect(surface.review_skill).to eq("skills/review/project.md")
    expect(surface.verification_commands).to eq(["commands/verify-all"])
    expect(surface.remediation_commands).to eq(["commands/apply-remediation"])
    expect(surface.workspace_hook).to eq("hooks/prepare-runtime.sh")
  end

  it "maps parent_review phase skill to the parent review runtime variant" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/default.md"
          },
          "parent_review" => {
            "skill" => "skills/review/parent.md"
          }
        }
      }
    )

    surface = loader.load(project_config_path)

    expect(surface.resolve(:review_skill, task_kind: :parent, repo_scope: :both, phase: :review))
      .to eq("skills/review/parent.md")
    expect(surface.resolve(:review_skill, task_kind: :child, repo_scope: :repo_alpha, phase: :implementation))
      .to eq("skills/review/default.md")
  end

  it "deep-freezes resolved phase surface structures" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/default.md"
          },
          "parent_review" => {
            "skill" => "skills/review/parent.md"
          }
        }
      }
    )

    surface = loader.load(project_config_path)

    expect(surface.review_skill).to be_frozen
    expect(surface.review_skill.fetch("variants")).to be_frozen
    expect(surface.review_skill.fetch("variants").fetch("task_kind")).to be_frozen
    expect do
      surface.review_skill.fetch("variants").fetch("task_kind")["parent"] = {}
    end.to raise_error(FrozenError)
  end

  it "rejects legacy runtime.surface" do
    project_config_path = write_project_config(
      "runtime" => {
        "surface" => {
          "implementation_skill" => "skills/implementation/base.md"
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.surface is no longer supported; use runtime.phases")
  end

  it "rejects legacy runtime.executor" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => { "skill" => "skills/implementation/base.md" },
          "review" => { "skill" => "skills/review/default.md" }
        },
        "executor" => {}
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.executor is no longer supported; use runtime.phases.<phase>.executor")
  end

  it "rejects legacy runtime.merge" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => { "skill" => "skills/implementation/base.md" },
          "review" => { "skill" => "skills/review/default.md" }
        },
        "merge" => {}
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.merge is no longer supported; use runtime.phases.merge")
  end

  it "rejects legacy runtime.presets" do
    project_config_path = write_project_config("runtime" => {"presets" => ["base"]})

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.presets is no longer supported; use runtime.phases")
  end

  it "rejects legacy manifest.yml paths" do
    project_config_path = File.join(@tmpdir, "manifest.yml")
    File.write(project_config_path, YAML.dump({ "schema_version" => 1, "runtime" => { "phases" => {} } }))

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
