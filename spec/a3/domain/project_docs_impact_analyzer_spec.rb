# frozen_string_literal: true

require "tmpdir"
require "a3/domain"

RSpec.describe A3::Domain::ProjectDocsImpactAnalyzer do
  around do |example|
    Dir.mktmpdir do |dir|
      @repo_root = dir
      example.run
    end
  end

  it "classifies docs impact and selects traceable candidate docs" do
    write_file(
      "docs/shared/project-package-schema.md",
      <<~MARKDOWN
        ---
        title: Project Package Schema
        category: shared_specs
        status: active
        related_requirements:
          - A2O#385
        related_tickets:
          - A2O#388
        source_issues:
          - wamukat/a2o#53
        authorities:
          - project_package_schema
        ---

        Project package schema constraints.
      MARKDOWN
    )
    write_file("project.yaml", "name: sample\n")
    index = A3::Domain::ProjectDocsIndex.load(
      repo_root: @repo_root,
      docs_config: {
        "root" => "docs",
        "categories" => {
          "shared_specs" => { "path" => "docs/shared" }
        },
        "authorities" => {
          "project_package_schema" => { "source" => "project.yaml" }
        }
      }
    )
    task = A3::Domain::Task.new(ref: "A2O#388", kind: :child, edit_scope: [:repo_alpha], parent_ref: "A2O#385")
    packet = task_packet(
      ref: task.ref,
      title: "Update project-package schema docs",
      description: "Handle wamukat/a2o#53 and shared config schema behavior."
    )

    decision = described_class.new(docs_index: index).analyze(task: task, task_packet: packet)

    expect(decision.decision).to eq("yes")
    expect(decision.categories).to include("shared_specs", "interfaces")
    expect(decision.matched_rules).to include("keyword:shared->shared_specs")
    expect(decision.candidate_docs.map(&:path)).to include("docs/shared/project-package-schema.md")
    expect(decision.candidate_docs.map(&:reason)).to include("related_requirement:A2O#385", "related_ticket:A2O#388", "source_issue:wamukat/a2o#53")
    expect(decision.authorities).to eq([{ "name" => "project_package_schema", "declaration" => { "source" => "project.yaml" } }])
    expect(decision.request_form.fetch("authority_sources")).to include(
      hash_including(
        "name" => "project_package_schema",
        "source" => "project.yaml",
        "exists" => true
      )
    )
    expect(decision.request_form.fetch("authority_precedence")).to eq(%w[authority_source docs evidence_artifacts ticket_text])
  end

  it "treats ACL and external API specs as shared-spec constraints" do
    write_file(
      "docs/acl/roles.md",
      <<~MARKDOWN
        ---
        title: Role Matrix
        category: acl
        status: active
        ---

        Shared authorization role constraints.
      MARKDOWN
    )
    write_file(
      "docs/api/openapi.md",
      <<~MARKDOWN
        ---
        title: External API Contract
        category: external_api
        status: active
        authorities:
          - openapi
        ---

        External API integration constraints.
      MARKDOWN
    )
    write_file("spec/openapi.yaml", "openapi: 3.1.0\n")
    index = A3::Domain::ProjectDocsIndex.load(
      repo_root: @repo_root,
      docs_config: {
        "root" => "docs",
        "categories" => {
          "acl" => { "path" => "docs/acl" },
          "external_api" => { "path" => "docs/api" }
        },
        "authorities" => {
          "openapi" => { "source" => "spec/openapi.yaml" }
        }
      }
    )
    task = A3::Domain::Task.new(ref: "A2O#392", kind: :child, edit_scope: [:repo_alpha])
    packet = task_packet(
      ref: task.ref,
      title: "Add role-based external API integration",
      description: "Change ACL permissions and OpenAPI webhook behavior."
    )

    decision = described_class.new(docs_index: index).analyze(task: task, task_packet: packet)

    expect(decision.categories).to include("acl", "external_api")
    expect(decision.candidate_docs.map(&:path)).to include("docs/acl/roles.md", "docs/api/openapi.md")
    expect(decision.request_form.fetch("authority_sources")).to include(
      hash_including("name" => "openapi", "source" => "spec/openapi.yaml", "exists" => true)
    )
  end

  it "records maybe for matched docs-impact rules without a candidate doc" do
    index = A3::Domain::ProjectDocsIndex.load(repo_root: @repo_root, docs_config: { "root" => "docs" })
    task = A3::Domain::Task.new(ref: "A2O#1", kind: :single, edit_scope: [:repo_alpha])
    packet = task_packet(
      ref: task.ref,
      title: "Add runtime scheduler config",
      description: "This changes a runtime scheduler config boundary."
    )

    decision = described_class.new(docs_index: index).analyze(task: task, task_packet: packet)

    expect(decision.decision).to eq("maybe")
    expect(decision.categories).to include("architecture", "interfaces")
    expect(decision.candidate_docs).to be_empty
  end

  it "keeps repo-local docs scoped while always exposing integration surfaces" do
    app_root = File.join(@repo_root, "app")
    lib_root = File.join(@repo_root, "lib")
    docs_root = File.join(@repo_root, "docs")
    write_file("app/docs/features/greeting.md", <<~MARKDOWN)
      ---
      title: Greeting UI
      category: features
      ---

      App behavior.
    MARKDOWN
    write_file("lib/docs/shared-specs/greeting-format.md", <<~MARKDOWN)
      ---
      title: Greeting Format
      category: shared_specs
      ---

      Shared spec.
    MARKDOWN
    write_file("docs/docs/interfaces/greeting-api.md", <<~MARKDOWN)
      ---
      title: Greeting API
      category: interfaces
      ---

      Integration contract.
    MARKDOWN
    index = A3::Domain::ProjectDocsIndex.load(
      repo_root: docs_root,
      repo_roots: { "app" => app_root, "lib" => lib_root, "docs" => docs_root },
      docs_config: {
        "surfaces" => {
          "app" => { "repoSlot" => "app", "root" => "docs", "categories" => { "features" => { "path" => "docs/features" } } },
          "lib" => { "repoSlot" => "lib", "root" => "docs", "categories" => { "shared_specs" => { "path" => "docs/shared-specs" } } },
          "integrated" => { "repoSlot" => "docs", "role" => "integration", "root" => "docs", "categories" => { "interfaces" => { "path" => "docs/interfaces" } } }
        }
      }
    )
    task = A3::Domain::Task.new(ref: "A2O#426", kind: :child, edit_scope: [:lib])
    packet = task_packet(
      ref: task.ref,
      title: "Update shared greeting API",
      description: "Change shared API behavior.",
      edit_scope: [:lib]
    )

    decision = described_class.new(docs_index: index).analyze(task: task, task_packet: packet)
    form = decision.request_form

    expect(form.fetch("surfaces")).to include(
      hash_including("id" => "lib", "repo_slot" => "lib"),
      hash_including("id" => "integrated", "repo_slot" => "docs", "role" => "integration")
    )
    expect(form.fetch("candidate_docs")).to include(
      hash_including("path" => "docs/shared-specs/greeting-format.md", "surface_id" => "lib", "repo_slot" => "lib"),
      hash_including("path" => "docs/interfaces/greeting-api.md", "surface_id" => "integrated", "repo_slot" => "docs", "role" => "integration")
    )
    expect(form.fetch("candidate_docs")).not_to include(hash_including("surface_id" => "app"))
  end

  def task_packet(ref:, title:, description:, edit_scope: [:repo_alpha])
    A3::Domain::WorkerTaskPacket.new(
      ref: ref,
      external_task_id: nil,
      kind: :child,
      edit_scope: edit_scope,
      verification_scope: edit_scope,
      parent_ref: nil,
      child_refs: [],
      title: title,
      description: description,
      status: "To do",
      labels: []
    )
  end

  def write_file(path, content)
    absolute_path = File.join(@repo_root, path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, content)
  end
end
