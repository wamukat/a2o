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
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          },
          "verification" => {
            "commands" => ["commands/verify-all"]
          },
          "remediation" => {
            "commands" => ["commands/apply-remediation"]
          },
          "metrics" => {
            "commands" => ["commands/collect-metrics"]
          }
        }
      }
    )

    surface = loader.load(project_config_path)

    expect(surface.implementation_skill).to eq("skills/implementation/base.md")
    expect(surface.review_skill).to eq("skills/review/project.md")
    expect(surface.verification_commands).to eq(["commands/verify-all"])
    expect(surface.remediation_commands).to eq(["commands/apply-remediation"])
    expect(surface.metrics_collection_commands).to eq(["commands/collect-metrics"])
    expect(surface.workspace_hook).to be_nil
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

  it "loads verification and remediation command variants" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/default.md"
          },
          "verification" => {
            "commands" => {
              "default" => ["commands/verify-all"],
              "variants" => {
            "task_kind" => {
              "single" => {
                "default" => ["commands/verify-single"]
              },
              "parent" => {
                "default" => ["commands/verify-parent-default"],
                "repo_scope" => {
                  "both" => {
                    "default" => ["commands/verify-parent-both-default"],
                    "phase" => {
                      "verification" => ["commands/verify-parent"]
                    }
                      }
                    }
                  }
                }
              }
            }
          },
          "remediation" => {
            "commands" => {
              "default" => ["commands/format-all"],
              "variants" => {
                "task_kind" => {
                  "child" => {
                    "repo_scope" => {
                      "repo_beta" => {
                        "phase" => {
                          "verification" => ["commands/format-storefront"]
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    )

    surface = loader.load(project_config_path)

    expect(surface.resolve(:verification_commands, task_kind: :parent, repo_scope: :both, phase: :verification))
      .to eq(["commands/verify-parent"])
    expect(surface.resolve(:verification_commands, task_kind: :parent, repo_scope: :both, phase: :review))
      .to eq(["commands/verify-parent-both-default"])
    expect(surface.resolve(:verification_commands, task_kind: :parent, repo_scope: :repo_alpha, phase: :verification))
      .to eq(["commands/verify-parent-default"])
    expect(surface.resolve(:verification_commands, task_kind: :single, repo_scope: :both, phase: :verification))
      .to eq(["commands/verify-single"])
    expect(surface.resolve(:verification_commands, task_kind: :child, repo_scope: :repo_beta, phase: :verification))
      .to eq(["commands/verify-all"])
    expect(surface.resolve(:remediation_commands, task_kind: :child, repo_scope: :repo_beta, phase: :verification))
      .to eq(["commands/format-storefront"])
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

  it "rejects legacy runtime.live_ref" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => { "skill" => "skills/implementation/base.md" },
          "review" => { "skill" => "skills/review/default.md" }
        },
        "live_ref" => "refs/heads/main"
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.live_ref is no longer supported; use runtime.phases.merge.target_ref")
  end

  it "rejects legacy phase workspace_hook" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md",
            "workspace_hook" => "hooks/prepare-runtime.sh"
          },
          "review" => { "skill" => "skills/review/default.md" }
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.workspace_hook is no longer supported; use phase commands or project package commands")
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
