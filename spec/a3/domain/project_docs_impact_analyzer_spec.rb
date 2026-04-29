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
    expect(decision.request_form.fetch("authority_precedence")).to eq(%w[authority_source docs evidence_artifacts ticket_text])
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

  def task_packet(ref:, title:, description:)
    A3::Domain::WorkerTaskPacket.new(
      ref: ref,
      external_task_id: nil,
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha],
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
