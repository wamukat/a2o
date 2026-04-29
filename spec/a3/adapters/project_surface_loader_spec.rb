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

  it "loads runtime notification hooks" do
    project_config_path = write_project_config(
      "runtime" => {
        "notifications" => {
          "failure_policy" => "blocking",
          "hooks" => [
            {
              "event" => "task.blocked",
              "command" => ["commands/notify"]
            }
          ]
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )

    surface = loader.load(project_config_path)

    expect(surface.notification_config.failure_policy).to eq("blocking")
    expect(surface.notification_config.hooks.map(&:persisted_form)).to eq(
      [
        {
          "event" => "task.blocked",
          "command" => ["commands/notify"]
        }
      ]
    )
  end

  it "rejects malformed runtime notification hooks" do
    project_config_path = write_project_config(
      "runtime" => {
        "notifications" => {
          "hooks" => [
            {
              "event" => "task.blocked",
              "command" => "commands/notify"
            }
          ]
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, /runtime\.notifications\.hooks\[0\]\.command/)
  end

  it "loads project prompt and skill configuration schema" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "system" => {
            "file" => "prompts/system.md"
          },
          "phases" => {
            "implementation" => {
              "prompt" => "prompts/implementation.md",
              "skills" => ["skills/testing-policy.md"]
            },
            "implementation_rework" => {
              "prompt" => "prompts/implementation-rework.md"
            },
            "decomposition" => {
              "prompt" => "prompts/decomposition.md",
              "childDraftTemplate" => "prompts/decomposition-child-template.md"
            }
          },
          "repoSlots" => {
            "app" => {
              "phases" => {
                "review" => {
                  "prompt" => "prompts/app-review.md",
                  "skills" => ["skills/app-review.md"]
                }
              }
            }
          }
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )
    write_project_files(
      "prompts/system.md" => "system guidance",
      "prompts/implementation.md" => "implementation guidance",
      "skills/testing-policy.md" => "test policy",
      "prompts/implementation-rework.md" => "rework guidance",
      "prompts/decomposition.md" => "decomposition guidance",
      "prompts/decomposition-child-template.md" => "child template",
      "prompts/app-review.md" => "app review prompt",
      "skills/app-review.md" => "app review skill"
    )

    prompt_config = loader.load(project_config_path).prompt_config

    expect(prompt_config.system_file).to eq("prompts/system.md")
    expect(prompt_config.system_document.content).to eq("system guidance")
    expect(prompt_config.phase(:implementation).prompt_file).to eq("prompts/implementation.md")
    expect(prompt_config.phase(:implementation).prompt_document.content).to eq("implementation guidance")
    expect(prompt_config.phase(:implementation).skill_files).to eq(["skills/testing-policy.md"])
    expect(prompt_config.phase(:implementation).skill_documents.map(&:content)).to eq(["test policy"])
    expect(prompt_config.phase(:implementation_rework).prompt_file).to eq("prompts/implementation-rework.md")
    expect(prompt_config.phase(:decomposition).child_draft_template_file).to eq("prompts/decomposition-child-template.md")
    expect(prompt_config.repo_slot_phase(:app, :implementation).prompt_file).to eq("prompts/implementation.md")
    expect(prompt_config.repo_slot_phase(:app, :implementation).skill_files).to eq(["skills/testing-policy.md"])
    expect(prompt_config.repo_slot_phase(:app, :review).skill_files).to eq(["skills/app-review.md"])
    expect(prompt_config.persisted_form).to include(
      "system" => { "file" => "prompts/system.md" }
    )
  end

  it "falls back implementation_rework to implementation when no rework profile is configured" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "prompt" => "prompts/implementation.md",
              "skills" => ["skills/testing-policy.md"]
            }
          }
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )
    write_project_files(
      "prompts/implementation.md" => "implementation guidance",
      "skills/testing-policy.md" => "test policy"
    )

    rework_config = loader.load(project_config_path).prompt_config.phase(:implementation_rework)

    expect(rework_config.prompt_file).to eq("prompts/implementation.md")
    expect(rework_config.skill_files).to eq(["skills/testing-policy.md"])
  end

  it "resolves repo-slot prompt config as an additive layer over phase defaults" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "review" => {
              "prompt" => "prompts/review.md",
              "skills" => ["skills/base-review.md"]
            }
          },
          "repoSlots" => {
            "app" => {
              "phases" => {
                "review" => {
                  "prompt" => "prompts/app-review.md",
                  "skills" => ["skills/app-review.md"]
                }
              }
            }
          }
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )
    write_project_files(
      "prompts/review.md" => "review guidance",
      "skills/base-review.md" => "base review skill",
      "prompts/app-review.md" => "app review guidance",
      "skills/app-review.md" => "app review skill"
    )

    review_config = loader.load(project_config_path).prompt_config.repo_slot_phase(:app, :review)

    expect(review_config.prompt_file).to eq("prompts/app-review.md")
    expect(review_config.prompt_files).to eq(["prompts/review.md", "prompts/app-review.md"])
    expect(review_config.prompt_documents.map(&:content)).to eq(["review guidance", "app review guidance"])
    expect(review_config.skill_files).to eq(["skills/base-review.md", "skills/app-review.md"])
    expect(review_config.skill_documents.map(&:content)).to eq(["base review skill", "app review skill"])
  end

  it "uses an empty prompt config when runtime.prompts is absent" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )

    expect(loader.load(project_config_path).prompt_config).to be_empty
  end

  it "rejects malformed prompt configuration shapes" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "skills" => ["skills/testing-policy.md", ""]
            }
          }
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.phases.implementation.skills[1] must be a non-empty string")
  end

  it "rejects missing prompt files" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "prompt" => "prompts/missing.md"
            }
          }
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.phases.implementation.prompt file not found: prompts/missing.md")
  end

  it "rejects prompt paths outside the project package root" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "prompt" => "../outside.md"
            }
          }
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.phases.implementation.prompt must stay inside the project package root")
  end

  it "rejects prompt symlinks that resolve outside the project package root" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "prompt" => "prompts/escape.md"
            }
          }
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )
    outside_path = File.join(File.dirname(@tmpdir), "outside-prompt.md")
    File.write(outside_path, "outside")
    FileUtils.mkdir_p(File.join(@tmpdir, "prompts"))
    File.symlink(outside_path, File.join(@tmpdir, "prompts", "escape.md"))

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.phases.implementation.prompt must stay inside the project package root")
  end

  it "rejects prompt directories" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "prompt" => "prompts"
            }
          }
        },
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md"
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )
    FileUtils.mkdir_p(File.join(@tmpdir, "prompts"))

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.phases.implementation.prompt must reference a file: prompts")
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

  def write_project_files(files)
    files.each do |relative_path, content|
      path = File.join(@tmpdir, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end
end
