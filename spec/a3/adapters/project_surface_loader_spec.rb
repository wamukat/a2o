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
    expect(surface.implementation_completion_hooks).to eq([])
    expect(surface.scheduler_config.max_parallel_tasks).to eq(1)
    expect(surface.workspace_hook).to be_nil
  end

  it "loads implementation completion hooks" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md",
            "completion_hooks" => {
              "commands" => [
                {
                  "name" => "fmt",
                  "command" => "./scripts/a2o/fmt-apply.sh",
                  "mode" => "mutating"
                },
                {
                  "name" => "verify",
                  "command" => "./scripts/a2o/impl-verify.sh",
                  "mode" => "check",
                  "on_failure" => "rework"
                }
              ]
            }
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )

    surface = loader.load(project_config_path)

    expect(surface.implementation_completion_hooks).to eq(
      [
        {
          "name" => "fmt",
          "command" => "./scripts/a2o/fmt-apply.sh",
          "mode" => "mutating",
          "on_failure" => "rework"
        },
        {
          "name" => "verify",
          "command" => "./scripts/a2o/impl-verify.sh",
          "mode" => "check",
          "on_failure" => "rework"
        }
      ]
    )
  end

  it "rejects malformed implementation completion hooks" do
    project_config_path = write_project_config(
      "runtime" => {
        "phases" => {
          "implementation" => {
            "skill" => "skills/implementation/base.md",
            "completion_hooks" => {
              "commands" => [
                {
                  "name" => "verify",
                  "command" => "./scripts/a2o/impl-verify.sh",
                  "mode" => "observe"
                }
              ]
            }
          },
          "review" => {
            "skill" => "skills/review/project.md"
          }
        }
      }
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, /completion_hooks\.commands\[0\]\.mode/)
  end

  it "loads explicit single-task scheduler config" do
    project_config_path = write_project_config(
      "runtime" => {
        "scheduler" => {
          "max_parallel_tasks" => 1
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

    expect(surface.scheduler_config.max_parallel_tasks).to eq(1)
  end

  it "loads max_parallel_tasks greater than one for the bounded parallel scheduler" do
    project_config_path = write_project_config(
      "runtime" => {
        "scheduler" => {
          "max_parallel_tasks" => 2
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

    expect(surface.scheduler_config.max_parallel_tasks).to eq(2)
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

  it "allows prompt-backed implementation and review phases without legacy phase skills" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "prompt" => "prompts/implementation.md"
            },
            "review" => {
              "skills" => ["skills/review-policy.md"]
            },
            "decomposition" => {
              "prompt" => "prompts/decomposition.md"
            }
          }
        },
        "phases" => {
          "implementation" => {},
          "review" => {}
        },
        "decomposition" => {
          "investigate" => {
            "command" => ["commands/investigate.sh"]
          },
          "author" => {
            "command" => ["commands/author.sh"]
          }
        }
      }
    )
    write_project_files(
      "prompts/implementation.md" => "implementation guidance",
      "skills/review-policy.md" => "review guidance",
      "prompts/decomposition.md" => "decomposition guidance"
    )

    surface = loader.load(project_config_path)

    expect(surface.implementation_skill).to be_nil
    expect(surface.review_skill).to be_nil
    expect(surface.prompt_config.phase(:implementation).prompt_file).to eq("prompts/implementation.md")
    expect(surface.prompt_config.phase(:review).skill_files).to eq(["skills/review-policy.md"])
    expect(surface.decomposition_investigate_command).to eq(["commands/investigate.sh"])
    expect(surface.decomposition_author_command).to eq(["commands/author.sh"])
  end

  it "keeps phase skills required when no corresponding prompt phase is configured" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "system" => {
            "file" => "prompts/system.md"
          }
        },
        "phases" => {
          "implementation" => {},
          "review" => {}
        }
      }
    )
    write_project_files("prompts/system.md" => "system guidance")

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.phases.implementation.skill must be provided")
  end

  it "validates docs configuration for repo-slot-relative paths and authorities" do
    repo_root = File.join(@tmpdir, "docs-repo")
    FileUtils.mkdir_p(File.join(repo_root, "docs", "architecture"))
    File.write(File.join(repo_root, "openapi.yaml"), "openapi: 3.1.0\n")
    project_config_path = write_project_config(
      "repos" => {
        "app" => { "path" => "app" },
        "docs" => { "path" => "docs-repo" }
      },
      "docs" => {
        "repoSlot" => "docs",
        "root" => "docs",
        "index" => "docs/README.md",
        "policy" => { "missingRoot" => "create" },
        "categories" => {
          "architecture" => {
            "path" => "docs/architecture",
            "index" => "docs/architecture/README.md"
          }
        },
        "languages" => {
          "primary" => "ja",
          "secondary" => ["en"]
        },
        "impactPolicy" => { "defaultSeverity" => "warning" },
        "authorities" => {
          "openapi" => {
            "source" => "openapi.yaml",
            "docs" => ["docs/api.md"]
          }
        }
      },
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

    expect { loader.load(project_config_path) }.not_to raise_error
  end

  it "validates multi-repo docs surfaces and cross-repo authority docs" do
    app_root = File.join(@tmpdir, "app")
    lib_root = File.join(@tmpdir, "lib")
    docs_root = File.join(@tmpdir, "docs-repo")
    FileUtils.mkdir_p(File.join(app_root, "docs", "features"))
    FileUtils.mkdir_p(File.join(lib_root, "docs", "shared-specs"))
    FileUtils.mkdir_p(File.join(docs_root, "docs", "interfaces"))
    File.write(File.join(lib_root, "docs", "shared-specs", "greeting-format.md"), "# Greeting\n")
    project_config_path = write_project_config(
      "repos" => {
        "app" => { "path" => "app" },
        "lib" => { "path" => "lib" },
        "docs" => { "path" => "docs-repo" }
      },
      "docs" => {
        "surfaces" => {
          "app" => {
            "repoSlot" => "app",
            "root" => "docs",
            "categories" => {
              "features" => { "path" => "docs/features" }
            }
          },
          "lib" => {
            "repoSlot" => "lib",
            "root" => "docs",
            "categories" => {
              "shared_specs" => { "path" => "docs/shared-specs" }
            }
          },
          "integrated" => {
            "repoSlot" => "docs",
            "role" => "integration",
            "root" => "docs",
            "categories" => {
              "interfaces" => { "path" => "docs/interfaces" }
            }
          }
        },
        "authorities" => {
          "greeting_schema" => {
            "repoSlot" => "lib",
            "source" => "docs/shared-specs/greeting-format.md",
            "docs" => [
              { "surface" => "lib", "path" => "docs/shared-specs/greeting-format.md" },
              { "surface" => "integrated", "path" => "docs/interfaces/greeting-api.md" }
            ]
          }
        }
      },
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

    expect { loader.load(project_config_path) }.not_to raise_error
  end

  it "loads the Java reference product multi-surface docs config" do
    repo_root = File.expand_path("../../..", __dir__)
    project_config_path = File.join(repo_root, "reference-products", "java-spring-multi-module", "project-package", "project.yaml")

    expect { loader.load(project_config_path) }.not_to raise_error
  end

  it "rejects invalid docs repo slots, paths, and symlink escapes" do
    project_config_path = write_project_config(
      "repos" => {
        "app" => { "path" => "app" }
      },
      "docs" => {
        "repoSlot" => "backend",
        "root" => "docs"
      },
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

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml docs.repoSlot must match a repos entry: backend")

    repo_root = File.join(@tmpdir, "app")
    outside_path = File.join(@tmpdir, "outside-doc.md")
    FileUtils.mkdir_p(File.join(repo_root, "docs"))
    File.write(outside_path, "outside")
    File.symlink(outside_path, File.join(repo_root, "docs", "escape.md"))
    project_config_path = write_project_config(
      "repos" => {
        "app" => { "path" => "app" }
      },
      "docs" => {
        "root" => "docs/escape.md"
      },
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

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml docs.root must stay inside the docs repo slot")

    FileUtils.rm_f(File.join(repo_root, "docs", "escape.md"))
    outside_dir = File.join(@tmpdir, "outside-doc-dir")
    FileUtils.mkdir_p(outside_dir)
    File.symlink(outside_dir, File.join(repo_root, "docs", "outside"))
    project_config_path = write_project_config(
      "repos" => {
        "app" => { "path" => "app" }
      },
      "docs" => {
        "root" => "docs",
        "index" => "docs/outside/new.md"
      },
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

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml docs.index must stay inside the docs repo slot")
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

  it "rejects repo-slot rework skills that duplicate fallback implementation skills" do
    project_config_path = write_project_config(
      "repos" => {
        "app" => { "path" => "../app" }
      },
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "skills" => ["skills/common.md"]
            }
          },
          "repoSlots" => {
            "app" => {
              "phases" => {
                "implementation_rework" => {
                  "skills" => ["skills/common.md"]
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
    write_project_files("skills/common.md" => "common")

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.repoSlots.app.phases.implementation_rework.skills duplicates runtime.prompts.phases.implementation.skills entry: skills/common.md")
  end

  it "rejects repo-slot prompt addons that do not match a repo entry" do
    project_config_path = write_project_config(
      "repos" => {
        "app" => { "path" => "../app" }
      },
      "runtime" => {
        "prompts" => {
          "repoSlots" => {
            "backend" => {
              "phases" => {
                "review" => {
                  "skills" => ["skills/backend-review.md"]
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
    write_project_files("skills/backend-review.md" => "backend review skill")

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.repoSlots.backend must match a repos entry")
  end

  it "rejects unsupported prompt phases and duplicate repo-slot skills" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "implementation" => {
              "skills" => ["skills/common.md"]
            }
          },
          "repoSlots" => {
            "app" => {
              "phases" => {
                "deployment" => {
                  "skills" => ["skills/deploy.md"]
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
      "skills/common.md" => "common",
      "skills/deploy.md" => "deploy"
    )

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.repoSlots.app.phases.deployment is not a supported prompt phase")

    duplicate_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "review" => {
              "skills" => ["skills/common.md"]
            }
          },
          "repoSlots" => {
            "app" => {
              "phases" => {
                "review" => {
                  "skills" => ["skills/common.md"]
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

    expect { loader.load(duplicate_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.repoSlots.app.phases.review.skills duplicates runtime.prompts.phases.review.skills entry: skills/common.md")
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

  it "rejects child draft templates outside decomposition prompt phases" do
    project_config_path = write_project_config(
      "runtime" => {
        "prompts" => {
          "phases" => {
            "review" => {
              "childDraftTemplate" => "prompts/review-child-template.md"
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
    write_project_files("prompts/review-child-template.md" => "review template")

    expect { loader.load(project_config_path) }
      .to raise_error(A3::Domain::ConfigurationError, "project.yaml runtime.prompts.phases.review.childDraftTemplate is only supported for decomposition")
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
