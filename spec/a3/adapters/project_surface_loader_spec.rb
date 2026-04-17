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

  it "loads a project config from preset chain and project overrides" do
    write_yaml(
      "base.yml",
      {
        "implementation_skill" => "skills/implementation/base.md",
        "review_skill" => "skills/review/base.md",
        "verification_commands" => ["commands/verify-all"],
        "remediation_commands" => ["commands/apply-remediation"],
        "workspace_hook" => "hooks/prepare-runtime.sh"
      }
    )

    project_config_path = write_project_config(
      {
        "runtime" => {
          "presets" => ["base"],
          "surface" => {
            "review_skill" => "skills/review/project.md"
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

  it "fails fast when two presets define incompatible values for the same key" do
    write_yaml(
      "base.yml",
      {
        "implementation_skill" => "skills/implementation/base.md"
      }
    )
    write_yaml(
      "java-child.yml",
      {
        "implementation_skill" => "skills/implementation/java-child.md"
      }
    )

    project_config_path = write_project_config({ "runtime" => { "presets" => ["base", "java-child"] } })

    expect { loader.load(project_config_path) }.to raise_error(A3::Domain::ConfigurationConflictError)
  end

  it "resolves variants in task_kind -> repo_scope -> phase order" do
    write_yaml(
      "base.yml",
      {
        "review_skill" => {
          "default" => "skills/review/default.md",
          "variants" => {
            "task_kind" => {
              "parent" => {
                "repo_scope" => {
                  "repo_alpha" => {
                    "phase" => {
                      "review" => "skills/review/repo-alpha-parent.md"
                    }
                  }
                }
              }
            }
          }
        }
      }
    )

    project_config_path = write_project_config({ "runtime" => { "presets" => ["base"] } })
    surface = loader.load(project_config_path)

    expect(surface.resolve(:review_skill, task_kind: :parent, repo_scope: :repo_alpha, phase: :review))
      .to eq("skills/review/repo-alpha-parent.md")
    expect(surface.resolve(:review_skill, task_kind: :parent, repo_scope: :repo_beta, phase: :review))
      .to eq("skills/review/default.md")
  end

  it "deep-merges disjoint variant branches across presets" do
    write_yaml(
      "base.yml",
      {
        "review_skill" => {
          "default" => "skills/review/default.md",
          "variants" => {
            "task_kind" => {
              "parent" => {
                "repo_scope" => {
                  "repo_alpha" => {
                    "phase" => {
                      "review" => "skills/review/repo-alpha-parent.md"
                    }
                  }
                }
              }
            }
          }
        }
      }
    )
    write_yaml(
      "frontend-child.yml",
      {
        "review_skill" => {
          "default" => "skills/review/default.md",
          "variants" => {
            "task_kind" => {
              "parent" => {
                "repo_scope" => {
                  "repo_beta" => {
                    "phase" => {
                      "review" => "skills/review/repo-beta-parent.md"
                    }
                  }
                }
              }
            }
          }
        }
      }
    )

    project_config_path = write_project_config({ "runtime" => { "presets" => ["base", "frontend-child"] } })
    surface = loader.load(project_config_path)

    expect(surface.resolve(:review_skill, task_kind: :parent, repo_scope: :repo_alpha, phase: :review))
      .to eq("skills/review/repo-alpha-parent.md")
    expect(surface.resolve(:review_skill, task_kind: :parent, repo_scope: :repo_beta, phase: :review))
      .to eq("skills/review/repo-beta-parent.md")
  end

  it "deep-freezes resolved surface structures" do
    write_yaml(
      "base.yml",
      {
        "review_skill" => {
          "default" => "skills/review/default.md",
          "variants" => {
            "task_kind" => {
              "parent" => {
                "repo_scope" => {
                  "repo_alpha" => {
                    "phase" => {
                      "review" => "skills/review/repo-alpha-parent.md"
                    }
                  }
                }
              }
            }
          }
        }
      }
    )

    project_config_path = write_project_config({ "runtime" => { "presets" => ["base"] } })
    surface = loader.load(project_config_path)

    expect(surface.review_skill).to be_frozen
    expect(surface.review_skill.fetch("variants")).to be_frozen
    expect(surface.review_skill.fetch("variants").fetch("task_kind")).to be_frozen
    expect do
      surface.review_skill.fetch("variants").fetch("task_kind")["parent"] = {}
    end.to raise_error(FrozenError)
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

  def write_yaml(name, payload)
    File.write(File.join(@preset_dir, name), YAML.dump({ "schema_version" => "1" }.merge(payload)))
  end
end
