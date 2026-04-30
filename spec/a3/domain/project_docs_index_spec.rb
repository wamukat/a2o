# frozen_string_literal: true

require "tmpdir"
require "a3/domain"

RSpec.describe A3::Domain::ProjectDocsIndex do
  around do |example|
    Dir.mktmpdir do |dir|
      @repo_root = dir
      example.run
    end
  end

  it "discovers docs by category, refs, source issues, tickets, and authorities" do
    write_file(
      "docs/shared/prompt-composition.md",
      <<~MARKDOWN
        ---
        title: Prompt Composition Model
        category: shared_specs
        status: active
        related_requirements:
          - A2O#371
        source_issues:
          - wamukat/a2o#53
        related_tickets:
          - A2O#386
        authorities:
          - project_package_schema
        audience:
          - maintainer
          - ai_worker
        owners:
          - runtime
        supersedes:
          - docs/shared/old-prompt-composition.md
        ---

        Body.
      MARKDOWN
    )
    write_file("project-package/project.yaml", "name: sample\n")
    write_file(
      "docs/README.md",
      <<~MARKDOWN
        # Docs

        <!-- a2o-docs-index:start category=shared_specs -->
        - [Prompt Composition Model](shared/prompt-composition.md)
        <!-- a2o-docs-index:end -->
      MARKDOWN
    )

    index = described_class.load(
      repo_root: @repo_root,
      docs_config: {
        "root" => "docs",
        "index" => "docs/README.md",
        "categories" => {
          "shared_specs" => { "path" => "docs/shared" }
        },
        "authorities" => {
          "project_package_schema" => { "source" => "project-package/project.yaml" }
        }
      }
    )

    expect(index.diagnostics).to be_empty
    expect(index.by_category("shared_specs").map(&:path)).to eq(["docs/shared/prompt-composition.md"])
    expect(index.by_related_requirement("A2O#371").map(&:title)).to eq(["Prompt Composition Model"])
    expect(index.by_source_issue("wamukat/a2o#53").map(&:title)).to eq(["Prompt Composition Model"])
    expect(index.by_related_ticket("A2O#386").map(&:title)).to eq(["Prompt Composition Model"])
    expect(index.by_authority("project_package_schema").map(&:title)).to eq(["Prompt Composition Model"])
    expect(index.authority("project_package_schema")).to eq("source" => "project-package/project.yaml")
    expect(index.authority_sources.map(&:to_h)).to eq(
      [
        {
          name: "project_package_schema",
          source: "project-package/project.yaml",
          exists: true,
          path: "project-package/project.yaml"
        }
      ]
    )
    expect(index.authority_precedence("project_package_schema")).to eq(%w[authority_source docs evidence_artifacts ticket_text])
    expect(index.managed_index_blocks.map(&:content)).to eq(["- [Prompt Composition Model](shared/prompt-composition.md)"])
    expect(index.managed_index_blocks.map(&:category)).to eq(["shared_specs"])
  end

  it "discovers multiple category-managed index blocks in one file" do
    write_file(
      "docs/README.md",
      <<~MARKDOWN
        # Docs

        <!-- a2o-docs-index:start category=features -->
        - [Greeting](features/greeting.md)
        <!-- a2o-docs-index:end -->

        <!-- a2o-docs-index:start category=shared_specs -->
        - [Runtime Events](shared/runtime-events.md)
        <!-- a2o-docs-index:end -->
      MARKDOWN
    )

    index = described_class.load(repo_root: @repo_root, docs_config: { "root" => "docs", "index" => "docs/README.md" })

    expect(index.managed_index_blocks.map(&:category)).to eq(%w[features shared_specs])
    expect(index.managed_index_blocks.map(&:content)).to eq(
      [
        "- [Greeting](features/greeting.md)",
        "- [Runtime Events](shared/runtime-events.md)"
      ]
    )
  end

  it "still reads legacy managed index blocks for compatibility" do
    write_file(
      "docs/README.md",
      <<~MARKDOWN
        # Docs

        <!-- a2o:index:start -->
        - [Legacy](legacy.md)
        <!-- a2o:index:end -->
      MARKDOWN
    )

    index = described_class.load(repo_root: @repo_root, docs_config: { "root" => "docs", "index" => "docs/README.md" })

    expect(index.managed_index_blocks.map(&:content)).to eq(["- [Legacy](legacy.md)"])
    expect(index.managed_index_blocks.map(&:category)).to eq([nil])
  end

  it "records authority source drift when a declared source is missing" do
    write_file(
      "docs/shared/api.md",
      <<~MARKDOWN
        ---
        title: API
        category: external_api
        authorities:
          - openapi
        ---

        Body.
      MARKDOWN
    )

    index = described_class.load(
      repo_root: @repo_root,
      docs_config: {
        "root" => "docs",
        "authorities" => {
          "openapi" => { "source" => "spec/openapi.yaml" }
        }
      }
    )

    expect(index.authority_sources.map(&:to_h)).to include(
      name: "openapi",
      source: "spec/openapi.yaml",
      exists: false,
      path: "spec/openapi.yaml"
    )
    expect(index.diagnostics.map(&:to_h)).to include(
      severity: :warning,
      path: "spec/openapi.yaml",
      field: "authorities.openapi.source",
      message: "authority source is declared but missing"
    )
  end

  it "records actionable diagnostics for malformed front matter and lifecycle fields" do
    write_file(
      "docs/bad.md",
      <<~MARKDOWN
        ---
        title: 123
        category: features
        related_tickets: A2O#1
        kanban_status: Done
        ---

        Body.
      MARKDOWN
    )

    index = described_class.load(repo_root: @repo_root, docs_config: { "root" => "docs" })

    expect(index.documents.first.metadata).to include("category" => "features")
    expect(index.diagnostics.map { |diagnostic| [diagnostic.field, diagnostic.message] }).to include(
      ["title", "front matter title must be a non-empty string"],
      ["related_tickets", "front matter related_tickets must be an array of non-empty strings"],
      ["kanban_status", "front matter must not duplicate lifecycle state"]
    )
  end

  it "records mirror debt for missing mirrored language docs" do
    write_file(
      "docs/ja/features/greeting.md",
      <<~MARKDOWN
        ---
        title: Greeting
        category: features
        status: active
        related_requirements:
          - A2O#1
        related_tickets:
          - A2O#2
        ---

        Body.
      MARKDOWN
    )

    index = described_class.load(
      repo_root: @repo_root,
      docs_config: {
        "root" => "docs",
        "languages" => {
          "canonical" => "ja",
          "mirrored" => ["en"]
        },
        "impactPolicy" => {
          "mirrorPolicy" => "require_canonical_warn_mirror"
        }
      }
    )

    expect(index.mirror_debt.map(&:to_h)).to eq(
      [
        {
          source_path: "docs/ja/features/greeting.md",
          language: "en",
          expected_path: "docs/en/features/greeting.md"
        }
      ]
    )
  end

  def write_file(path, content)
    absolute_path = File.join(@repo_root, path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, content)
  end
end
