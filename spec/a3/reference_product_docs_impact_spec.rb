# frozen_string_literal: true

require "yaml"
require "a3/domain"

RSpec.describe "Java Spring reference product docs-impact config" do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:product_root) { File.join(repo_root, "reference-products", "java-spring-multi-module") }
  let(:package_root) { File.join(product_root, "project-package") }
  let(:project_config) { YAML.load_file(File.join(package_root, "project.yaml")) }
  let(:docs_config) { project_config.fetch("docs") }
  let(:docs_repo_root) { File.expand_path(project_config.fetch("repos").fetch("docs").fetch("path"), package_root) }

  it "provides a traceable docs-impact reference surface" do
    index = A3::Domain::ProjectDocsIndex.load(repo_root: docs_repo_root, docs_config: docs_config)

    expect(index.by_category("features").map(&:path)).to include("docs/features/greeting.md")
    expect(index.by_category("shared_specs").map(&:path)).to include("docs/shared-specs/greeting-format.md")
    expect(index.by_category("interfaces").map(&:path)).to include("docs/interfaces/greeting-api.md")
    expect(index.by_related_requirement("A2O#394").map(&:path)).to include(
      "docs/features/greeting.md",
      "docs/shared-specs/greeting-format.md",
      "docs/interfaces/greeting-api.md"
    )
    expect(index.by_source_issue("wamukat/a2o#16").map(&:path)).to include("docs/features/greeting.md")
    expect(index.authorities.keys).to include("greeting_api", "greeting_shared_spec")
    expect(docs_config.fetch("impactPolicy")).to include("mirrorPolicy" => "require_canonical_warn_mirror")
  end

  it "selects docs candidates for app, shared spec, and interface changes" do
    index = A3::Domain::ProjectDocsIndex.load(repo_root: docs_repo_root, docs_config: docs_config)
    task = A3::Domain::Task.new(ref: "A2O#394", kind: :child, edit_scope: %i[app lib docs], parent_ref: "A2O#385")
    packet = A3::Domain::WorkerTaskPacket.new(
      ref: task.ref,
      external_task_id: nil,
      kind: :child,
      edit_scope: %i[app lib docs],
      verification_scope: %i[app lib docs],
      parent_ref: task.parent_ref,
      child_refs: [],
      title: "Add Japanese greeting API support",
      description: "Handle wamukat/a2o#16 by changing the shared greeting spec and public interface.",
      status: "To do",
      labels: %w[repo:app repo:lib repo:docs]
    )

    decision = A3::Domain::ProjectDocsImpactAnalyzer.new(docs_index: index).analyze(task: task, task_packet: packet)

    expect(decision.decision).to eq("yes")
    expect(decision.categories).to include("shared_specs", "interfaces")
    expect(decision.candidate_docs.map(&:path)).to include(
      "docs/features/greeting.md",
      "docs/shared-specs/greeting-format.md",
      "docs/interfaces/greeting-api.md"
    )
    expect(decision.request_form.fetch("authority_sources")).to include(
      hash_including("name" => "greeting_api", "source" => "docs/interfaces/greeting-api.md", "exists" => true),
      hash_including("name" => "greeting_shared_spec", "source" => "docs/shared-specs/greeting-format.md", "exists" => true)
    )
  end
end
