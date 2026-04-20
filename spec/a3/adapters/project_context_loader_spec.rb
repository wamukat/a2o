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

  it "loads project surface and core merge config from runtime phases" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => base_phases.merge(
          "merge" => {
            "policy" => "ff_only",
            "target_ref" => "refs/heads/feature/prototype"
          }
        )
      }
    )

    context = loader.load(project_config_path)

    expect(context.surface.implementation_skill).to eq("skills/implementation/base.md")
    expect(context.surface.review_skill).to eq("skills/review/default.md")
    expect(context.surface.verification_commands).to eq(["commands/verify-all"])
    expect(context.merge_config.target).to eq(:merge_to_live)
    expect(context.merge_config.policy).to eq(:ff_only)
    expect(context.merge_config.target_ref).to eq("refs/heads/feature/prototype")
  end

  it "resolves verification and remediation command variants per task" do
    phases = base_phases.merge(
      "verification" => {
        "commands" => {
          "default" => ["commands/verify-all"],
          "variants" => {
            "task_kind" => {
              "parent" => {
                "repo_scope" => {
                  "both" => {
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
      },
      "merge" => {
        "policy" => "ff_only",
        "target_ref" => "refs/heads/feature/prototype"
      }
    )
    project_config_path = write_project_config("runtime" => {"phases" => phases})
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

    child_runtime = context.resolve_phase_runtime(task: child_task, phase: :verification)
    parent_runtime = context.resolve_phase_runtime(task: parent_task, phase: :verification)

    expect(child_runtime.verification_commands).to eq(["commands/verify-all"])
    expect(child_runtime.remediation_commands).to eq(["commands/format-storefront"])
    expect(parent_runtime.verification_commands).to eq(["commands/verify-parent"])
    expect(parent_runtime.remediation_commands).to eq(["commands/format-all"])
  end

  it "rejects public merge target configuration" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => base_phases.merge(
          "merge" => {
            "target" => "merge_to_parent",
            "policy" => "ff_only",
            "target_ref" => "refs/heads/feature/prototype"
          }
        )
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.target is no longer supported; A2O derives merge target from task topology")
  end

  it "rejects missing core merge config" do
    project_config_path = write_project_config("runtime" => {"phases" => base_phases})

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.policy and runtime.phases.merge.target_ref must be provided")
  end

  it "rejects missing core merge target ref" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => base_phases.merge(
          "merge" => {
            "policy" => "ff_only"
          }
        )
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.target_ref must be provided")
  end

  it "rejects blank core merge target ref" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => base_phases.merge(
          "merge" => {
            "policy" => "ff_only",
            "target_ref" => "   "
          }
        )
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.phases.merge.target_ref must not be blank")
  end

  it "rejects legacy runtime.executor" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => base_phases.merge(
          "merge" => {
            "policy" => "ff_only",
            "target_ref" => "refs/heads/feature/prototype"
          }
        ),
        "executor" => {}
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.executor is no longer supported; use runtime.phases.<phase>.executor")
  end

  it "rejects legacy runtime.merge" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => base_phases.merge(
          "merge" => {
            "policy" => "ff_only",
            "target_ref" => "refs/heads/feature/prototype"
          }
        ),
        "merge" => {}
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.merge is no longer supported; use runtime.phases.merge")
  end

  it "rejects legacy runtime.live_ref" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => base_phases.merge(
          "merge" => {
            "policy" => "ff_only",
            "target_ref" => "refs/heads/feature/prototype"
          }
        ),
        "live_ref" => "refs/heads/main"
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.live_ref is no longer supported; use runtime.phases.merge.target_ref")
  end

  it "loads task-kind-specific target ref variants while deriving merge targets from topology" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => base_phases.merge(
          "merge" => {
            "target_ref" => {
              "default" => "refs/heads/live",
              "variants" => {
                "task_kind" => {
                  "parent" => { "default" => "refs/heads/feature/prototype" }
                }
              }
            },
            "policy" => "ff_only"
          }
        )
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
    File.write(project_config_path, YAML.dump({ "schema_version" => 1, "runtime" => { "phases" => {} } }))

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "manifest.yml is no longer supported; use project.yaml")
  end

  private

  def base_phases
    {
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
      }
    }
  end

  def write_project_config(payload)
    path = File.join(@tmpdir, "project.yaml")
    File.write(path, YAML.dump({ "schema_version" => 1 }.merge(payload)))
    path
  end
end
