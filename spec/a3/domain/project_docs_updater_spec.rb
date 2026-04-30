# frozen_string_literal: true

require "tmpdir"
require "a3/domain"

RSpec.describe A3::Domain::ProjectDocsUpdater do
  around do |example|
    Dir.mktmpdir do |dir|
      @repo_root = dir
      example.run
    end
  end

  it "creates category docs with traceability metadata and updates managed index blocks" do
    write_file(
      "docs/README.md",
      <<~MARKDOWN
        # Docs

        Human introduction.

        <!-- a2o-docs-index:start category=shared_specs -->
        - [Existing Spec](shared/existing.md)
        <!-- a2o-docs-index:end -->

        Human appendix.
      MARKDOWN
    )

    result = described_class.update_document(
      repo_root: @repo_root,
      docs_config: docs_config,
      category: "shared_specs",
      title: "Prompt Composition Model",
      body: "Prompt composition details.\n",
      metadata: {
        "related_requirements" => ["A2O#385"],
        "related_tickets" => ["A2O#391"],
        "source_issues" => ["wamukat/a2o#53"],
        "authorities" => ["project_package_schema"]
      }
    )

    expect(result.diagnostics).to be_empty
    expect(result.updated_paths).to contain_exactly(
      "docs/shared/prompt-composition-model.md",
      "docs/README.md"
    )
    expect(read_file("docs/shared/prompt-composition-model.md")).to include(
      "title: Prompt Composition Model",
      "category: shared_specs",
      "related_requirements:",
      "- A2O#385",
      "Prompt composition details."
    )
    expect(read_file("docs/README.md")).to include("Human introduction.", "Human appendix.")
    expect(read_file("docs/README.md")).to include(
      "<!-- a2o-docs-index:start category=shared_specs -->\n" \
      "- [Existing Spec](shared/existing.md)\n" \
      "- [Prompt Composition Model](shared/prompt-composition-model.md)\n" \
      "<!-- a2o-docs-index:end -->"
    )

    second = described_class.update_document(
      repo_root: @repo_root,
      docs_config: docs_config,
      category: "shared_specs",
      title: "Prompt Composition Model",
      body: "Prompt composition details.\n",
      metadata: {
        "related_requirements" => ["A2O#385"],
        "related_tickets" => ["A2O#391"],
        "source_issues" => ["wamukat/a2o#53"],
        "authorities" => ["project_package_schema"]
      }
    )

    expect(second.updated_paths).to be_empty
  end

  it "updates front matter without removing human-authored fields or body" do
    write_file(
      "docs/shared/prompt-composition.md",
      <<~MARKDOWN
        ---
        title: Prompt Composition Model
        category: shared_specs
        custom_owner_note: keep me
        related_tickets:
        - A2O#386
        ---

        Human-authored body.
      MARKDOWN
    )

    result = described_class.update_document(
      repo_root: @repo_root,
      docs_config: docs_config,
      category: "shared_specs",
      title: "Prompt Composition Model",
      relative_path: "prompt-composition.md",
      metadata: {
        "related_tickets" => ["A2O#391"],
        "related_requirements" => ["A2O#385"]
      }
    )

    content = read_file("docs/shared/prompt-composition.md")
    expect(result.updated_paths).to eq(["docs/shared/prompt-composition.md"])
    expect(content).to include("custom_owner_note: keep me")
    expect(content).to include("- A2O#386", "- A2O#391")
    expect(content).to include("Human-authored body.")
  end

  it "records a review finding instead of rewriting indexes without managed blocks" do
    write_file(
      "docs/README.md",
      <<~MARKDOWN
        # Docs

        - [Human Link](shared/human.md)
      MARKDOWN
    )

    result = described_class.update_document(
      repo_root: @repo_root,
      docs_config: docs_config,
      category: "shared_specs",
      title: "Runtime Event Model",
      body: "Runtime events.\n",
      metadata: {
        "related_tickets" => ["A2O#391"]
      }
    )

    expect(result.updated_paths).to eq(["docs/shared/runtime-event-model.md"])
    expect(result.diagnostics.map(&:to_h)).to include(
      severity: :review_finding,
      path: "docs/README.md",
      field: nil,
      message: "index has no a2o-docs-index managed block; skipping broad rewrite"
    )
    expect(read_file("docs/README.md")).to include("- [Human Link](shared/human.md)")
  end

  it "keeps category-specific managed blocks isolated" do
    write_file(
      "docs/README.md",
      <<~MARKDOWN
        # Docs

        <!-- a2o-docs-index:start category=features -->
        - [Greeting](features/greeting.md)
        <!-- a2o-docs-index:end -->

        <!-- a2o-docs-index:start category=shared_specs -->
        <!-- a2o-docs-index:end -->
      MARKDOWN
    )

    described_class.update_document(
      repo_root: @repo_root,
      docs_config: docs_config,
      category: "shared_specs",
      title: "Runtime Event Model",
      body: "Runtime events.\n"
    )

    content = read_file("docs/README.md")
    expect(content).to include("- [Greeting](features/greeting.md)")
    expect(content).to include("- [Runtime Event Model](shared/runtime-event-model.md)")
  end

  it "rejects document paths that escape the repo slot" do
    result = described_class.update_document(
      repo_root: @repo_root,
      docs_config: docs_config,
      category: "shared_specs",
      title: "Escaping",
      relative_path: "../../escape.md",
      body: "bad\n"
    )

    expect(result.updated_paths).to be_empty
    expect(result.diagnostics.map(&:message)).to include("docs path must stay inside the configured category path")
  end

  def docs_config
    {
      "root" => "docs",
      "index" => "docs/README.md",
      "categories" => {
        "shared_specs" => { "path" => "docs/shared" },
        "features" => { "path" => "docs/features" }
      }
    }
  end

  def write_file(path, content)
    absolute_path = File.join(@repo_root, path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, content)
  end

  def read_file(path)
    File.read(File.join(@repo_root, path))
  end
end
