# frozen_string_literal: true

require "json"
require "spec_helper"
require "tmpdir"

RSpec.describe A3::Infra::WorkerProtocol do
  let(:tmpdir) { Dir.mktmpdir("a3-worker-protocol") }
  let(:workspace) do
    A3::Domain::PreparedWorkspace.new(
      workspace_kind: :runtime_workspace,
      root_path: Pathname(tmpdir).join("workspace"),
      source_descriptor: source_descriptor,
      slot_paths: {
        repo_beta: Pathname(tmpdir).join("workspace", "repo-beta")
      }
    )
  end
  let(:task) do
    A3::Domain::Task.new(
      ref: "A3-v2#3028",
      project_key: "portal",
      kind: :child,
      edit_scope: [:repo_beta],
      verification_scope: [:repo_beta]
    )
  end
  let(:run) do
    A3::Domain::Run.new(
      ref: "run-1",
      project_key: "portal",
      task_ref: task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :child
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :child,
        snapshot_version: "head-1"
      )
    )
  end
  let(:task_packet) do
    A3::Domain::WorkerTaskPacket.new(
      ref: task.ref,
      external_task_id: 3028,
      kind: task.kind,
      edit_scope: task.edit_scope,
      verification_scope: task.verification_scope,
      parent_ref: task.parent_ref,
      child_refs: task.child_refs,
      title: "Review worker protocol",
      description: "Review agent materialized worker protocol.",
      status: "In progress",
      labels: []
    )
  end
  let(:phase_runtime) do
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :ui_app,
      phase: :review,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash
    )
  end

  before do
    FileUtils.mkdir_p(workspace.root_path)
  end

  after do
    FileUtils.remove_entry(tmpdir)
  end

  it "exposes the same request payload that write_request persists" do
    protocol = described_class.new
    request_form = protocol.request_form(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    protocol.write_request(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    request_path = workspace.root_path.join(".a2o", "worker-request.json")
    persisted = JSON.parse(request_path.read)
    expect(persisted).to eq(request_form)
    expect(request_path.read).to include("\n  \"task_ref\":")
    expect(request_form).to include(
      "task_ref" => task.ref,
      "project_key" => "portal",
      "run_ref" => run.ref,
      "phase" => "review",
      "skill" => "task review"
    )
  end

  it "marks command request intent when used by project verification commands" do
    protocol = described_class.new
    request_form = protocol.request_form(
      skill: nil,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet,
      command_intent: :verification
    )

    expect(request_form).to include(
      "command_intent" => "verification",
      "slot_paths" => {
        "repo_beta" => workspace.slot_paths.fetch(:repo_beta).to_s
      },
      "phase_runtime" => hash_including(
        "task_kind" => "child",
        "repo_scope" => "ui_app"
      )
    )
  end

  it "embeds prior review feedback in phase_runtime when provided" do
    protocol = described_class.new
    request_form = protocol.request_form(
      skill: phase_runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet,
      prior_review_feedback: {
        "run_ref" => "run-review-1",
        "summary" => "Review found missing assertion coverage.",
        "observed_state" => "Only the happy path is asserted."
      }
    )

    expect(request_form.fetch("phase_runtime")).to include(
      "prior_review_feedback" => {
        "run_ref" => "run-review-1",
        "summary" => "Review found missing assertion coverage.",
        "observed_state" => "Only the happy path is asserted."
      }
    )
  end

  it "composes project prompt layers after core instruction and before ticket instruction" do
    prompt_config = A3::Domain::ProjectPromptConfig.new(
      system_document: prompt_document("prompts/system.md", "system guidance"),
      phases: {
        "review" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/review.md", "review guidance"),
          skill_documents: [
            prompt_document("skills/review-policy.md", "review policy")
          ]
        )
      }
    )
    runtime = phase_runtime_with_prompt_config(prompt_config)

    request_form = described_class.new.request_form(
      skill: runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: runtime,
      task_packet: task_packet
    )

    project_prompt = request_form.fetch("phase_runtime").fetch("project_prompt")
    expect(project_prompt.fetch("profile")).to eq("review")
    expect(project_prompt.fetch("layers").map { |layer| layer.fetch("kind") }).to eq(
      %w[
        a2o_core_instruction
        project_system_prompt
        project_phase_prompt
        project_phase_skill
        ticket_phase_instruction
      ]
    )
    expect(project_prompt.fetch("composed_instruction")).to include("## A2O core instruction\n#{runtime.review_skill}")
    expect(project_prompt.fetch("composed_instruction")).to include("## prompts/system.md\nsystem guidance")
    expect(project_prompt.fetch("composed_instruction")).to include("## ticket #{task.ref}\nTask: #{task.ref}")

    metadata = described_class.new.project_prompt_metadata(request_form)
    expect(metadata.fetch("profile")).to eq("review")
    expect(metadata.fetch("effective_profile")).to eq("review")
    expect(metadata.fetch("project_package_schema_version")).to eq("1")
    expect(metadata.fetch("layers").map { |layer| layer.fetch("title") }).to include("prompts/system.md", "prompts/review.md", "skills/review-policy.md")
    expect(metadata.fetch("layers").first).to include("content_sha256", "content_bytes")
    expect(metadata.to_s).not_to include("system guidance")
  end

  it "selects implementation_rework prompt profile when prior review feedback is present" do
    implementation_run = A3::Domain::Run.new(
      ref: "run-implementation-1",
      project_key: "portal",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_beta],
        verification_scope: [:repo_beta],
        ownership_scope: :child
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :child,
        snapshot_version: "head-1"
      )
    )
    prompt_config = A3::Domain::ProjectPromptConfig.new(
      phases: {
        "implementation" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/implementation.md", "implementation guidance")
        ),
        "implementation_rework" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/rework.md", "rework guidance")
        )
      }
    )
    runtime = phase_runtime_with_prompt_config(prompt_config, phase: :implementation)

    request_form = described_class.new.request_form(
      skill: runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: implementation_run,
      phase_runtime: runtime,
      task_packet: task_packet,
      prior_review_feedback: { "summary" => "Fix assertion coverage." }
    )

    project_prompt = request_form.fetch("phase_runtime").fetch("project_prompt")
    expect(project_prompt.fetch("profile")).to eq("implementation_rework")
    expect(project_prompt.fetch("composed_instruction")).to include("rework guidance")
    expect(project_prompt.fetch("composed_instruction")).not_to include("implementation guidance")
    expect(request_form.fetch("phase_runtime")).to include("prior_review_feedback" => { "summary" => "Fix assertion coverage." })
  end

  it "records implementation rework fallback profile metadata" do
    prompt_config = A3::Domain::ProjectPromptConfig.new(
      phases: {
        "implementation" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/implementation.md", "implementation guidance")
        )
      }
    )
    runtime = phase_runtime_with_prompt_config(prompt_config, phase: :implementation)

    request_form = described_class.new.request_form(
      skill: runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: implementation_run,
      phase_runtime: runtime,
      task_packet: task_packet,
      prior_review_feedback: { "summary" => "Fix assertion coverage." }
    )

    project_prompt = request_form.fetch("phase_runtime").fetch("project_prompt")
    expect(project_prompt.fetch("profile")).to eq("implementation_rework")
    expect(project_prompt.fetch("effective_profile")).to eq("implementation")
    expect(project_prompt.fetch("fallback_profile")).to eq("implementation")
    expect(project_prompt.fetch("composed_instruction")).to include("implementation guidance")

    metadata = described_class.new.project_prompt_metadata(request_form)
    expect(metadata.fetch("profile")).to eq("implementation_rework")
    expect(metadata.fetch("effective_profile")).to eq("implementation")
    expect(metadata.fetch("fallback_profile")).to eq("implementation")
    expect(metadata.fetch("layers").map { |layer| layer.fetch("title") }).to include("prompts/implementation.md")
  end

  it "adds docs-impact context to implementation worker requests" do
    docs_root = workspace.slot_paths.fetch(:repo_beta).join("docs", "shared")
    FileUtils.mkdir_p(docs_root)
    docs_root.join("project-package-schema.md").write(
      <<~MARKDOWN
        ---
        title: Project Package Schema
        category: shared_specs
        status: active
        related_tickets:
          - #{task.ref}
        authorities:
          - project_package_schema
        ---

        Schema constraints for workers.
      MARKDOWN
    )
    runtime = A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :repo_beta,
      phase: :implementation,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash,
      docs_config: {
        "repoSlot" => "repo_beta",
        "root" => "docs",
        "categories" => {
          "shared_specs" => { "path" => "docs/shared" }
        },
        "languages" => {
          "primary" => "en",
          "secondary" => ["ja"]
        },
        "authorities" => {
          "project_package_schema" => { "source" => "project.yaml" }
        }
      }
    )
    implementation_packet = A3::Domain::WorkerTaskPacket.new(
      ref: task.ref,
      external_task_id: task.external_task_id,
      kind: task.kind,
      edit_scope: task.edit_scope,
      verification_scope: task.verification_scope,
      parent_ref: task.parent_ref,
      child_refs: task.child_refs,
      title: "Update project-package schema",
      description: "Change shared schema behavior.",
      status: "In progress",
      labels: []
    )

    request_form = described_class.new.request_form(
      skill: runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: implementation_run,
      phase_runtime: runtime,
      task_packet: implementation_packet
    )

    docs_context = request_form.fetch("docs_context")
    expect(docs_context.fetch("decision")).to eq("yes")
    expect(docs_context.fetch("request_phase")).to eq("implementation")
    expect(docs_context.fetch("config_summary")).to include(
      "root" => "docs",
      "repo_slot" => "repo_beta",
      "categories" => ["shared_specs"],
      "authorities" => ["project_package_schema"]
    )
    expect(docs_context.fetch("expected_actions")).to include("update_or_confirm_candidate_docs", "record_docs_impact_evidence")
    expect(docs_context.fetch("language_policy")).to include(
      "primary" => "en",
      "mirrors" => ["ja"]
    )
    expect(docs_context.fetch("traceability_refs")).to include(task.ref)
    expect(docs_context.fetch("categories")).to include("shared_specs")
    expect(docs_context.fetch("candidate_docs")).to include(
      hash_including(
        "path" => "docs/shared/project-package-schema.md",
        "title" => "Project Package Schema",
        "reason" => "related_ticket:#{task.ref}",
        "excerpt" => "Schema constraints for workers."
      )
    )
    expect(docs_context.fetch("authority_precedence")).to eq(%w[authority_source docs evidence_artifacts ticket_text])
  end

  it "adds docs-impact context to review and parent-review worker requests when docs are configured" do
    docs_root = workspace.slot_paths.fetch(:repo_beta).join("docs", "shared")
    FileUtils.mkdir_p(docs_root)
    docs_root.join("review-policy.md").write(
      <<~MARKDOWN
        ---
        title: Review Policy
        category: shared_specs
        status: active
        related_tickets:
          - #{task.ref}
        ---

        Review docs-impact evidence and shared-spec updates.
      MARKDOWN
    )
    runtime = A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :parent,
      repo_scope: :repo_beta,
      phase: :review,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash,
      docs_config: {
        "repoSlot" => "repo_beta",
        "root" => "docs",
        "categories" => {
          "shared_specs" => { "path" => "docs/shared" }
        }
      }
    )

    request_form = described_class.new.request_form(
      skill: runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: runtime,
      task_packet: task_packet
    )

    docs_context = request_form.fetch("docs_context")
    expect(docs_context.fetch("request_phase")).to eq("parent_review")
    expect(docs_context.fetch("candidate_docs")).to include(
      hash_including("path" => "docs/shared/review-policy.md")
    )
  end

  it "keeps repo-slot implementation_rework addons when the base profile falls back to implementation" do
    prompt_config = A3::Domain::ProjectPromptConfig.new(
      phases: {
        "implementation" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/implementation.md", "implementation guidance")
        )
      },
      repo_slots: {
        "ui_app" => {
          "implementation_rework" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
            prompt_document: prompt_document("prompts/ui-rework.md", "ui rework guidance")
          )
        }
      }
    )
    runtime = phase_runtime_with_prompt_config(prompt_config, phase: :implementation, repo_scope: :ui_app)

    request_form = described_class.new.request_form(
      skill: runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: implementation_run,
      phase_runtime: runtime,
      task_packet: task_packet,
      prior_review_feedback: { "summary" => "Fix assertion coverage." }
    )

    project_prompt = request_form.fetch("phase_runtime").fetch("project_prompt")
    expect(project_prompt.fetch("profile")).to eq("implementation_rework")
    expect(project_prompt.fetch("effective_profile")).to eq("implementation")
    expect(project_prompt.fetch("fallback_profile")).to eq("implementation")
    expect(project_prompt.fetch("composed_instruction")).to include("implementation guidance")
    expect(project_prompt.fetch("composed_instruction")).to include("ui rework guidance")

    metadata = described_class.new.project_prompt_metadata(request_form)
    expect(metadata.fetch("repo_slot")).to eq("ui_app")
    expect(metadata.fetch("repo_slots")).to eq(["ui_app"])
    expect(metadata.fetch("layers").map { |layer| layer.fetch("title") }).to include(
      "prompts/implementation.md",
      "ui_app:prompts/ui-rework.md"
    )
  end

  it "selects parent_review prompt profile for parent review runs" do
    parent_task = A3::Domain::Task.new(
      ref: "A3-v2#3000",
      project_key: "portal",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      child_refs: [task.ref]
    )
    parent_run = A3::Domain::Run.new(
      ref: "run-parent-review-1",
      project_key: "portal",
      task_ref: parent_task.ref,
      phase: :review,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: parent_task.edit_scope,
        verification_scope: parent_task.verification_scope,
        ownership_scope: :parent
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: parent_task.ref,
        owner_scope: :parent,
        snapshot_version: "head-1"
      )
    )
    parent_packet = A3::Domain::WorkerTaskPacket.new(
      ref: parent_task.ref,
      external_task_id: nil,
      kind: parent_task.kind,
      edit_scope: parent_task.edit_scope,
      verification_scope: parent_task.verification_scope,
      parent_ref: nil,
      child_refs: parent_task.child_refs,
      title: "Review child integration",
      description: "Check whether children can be integrated.",
      status: "In review",
      labels: []
    )
    prompt_config = A3::Domain::ProjectPromptConfig.new(
      phases: {
        "review" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/review.md", "child review guidance")
        ),
        "parent_review" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/parent-review.md", "parent integration guidance")
        )
      }
    )
    runtime = A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :parent,
      repo_scope: :both,
      phase: :review,
      implementation_skill: "task implementation",
      review_skill: "parent review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash,
      project_prompt_config: prompt_config
    )

    request_form = described_class.new.request_form(
      skill: runtime.review_skill,
      workspace: workspace,
      task: parent_task,
      run: parent_run,
      phase_runtime: runtime,
      task_packet: parent_packet
    )

    project_prompt = request_form.fetch("phase_runtime").fetch("project_prompt")
    expect(project_prompt.fetch("profile")).to eq("parent_review")
    expect(project_prompt.fetch("composed_instruction")).to include("parent integration guidance")
    expect(project_prompt.fetch("composed_instruction")).not_to include("child review guidance")
  end

  it "adds repo-slot prompt layers without replacing project phase defaults" do
    prompt_config = A3::Domain::ProjectPromptConfig.new(
      phases: {
        "implementation" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/implementation.md", "implementation guidance"),
          skill_documents: [prompt_document("skills/common-testing.md", "common testing")]
        )
      },
      repo_slots: {
        "ui_app" => {
          "implementation" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
            prompt_document: prompt_document("prompts/ui-implementation.md", "ui guidance"),
            skill_documents: [prompt_document("skills/playwright.md", "browser testing")]
          )
        }
      }
    )
    runtime = phase_runtime_with_prompt_config(prompt_config, phase: :implementation, repo_scope: :ui_app)

    request_form = described_class.new.request_form(
      skill: runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: implementation_run,
      phase_runtime: runtime,
      task_packet: task_packet
    )

    project_prompt = request_form.fetch("phase_runtime").fetch("project_prompt")
    expect(project_prompt.fetch("layers").map { |layer| layer.fetch("kind") }).to include(
      "project_phase_prompt",
      "project_phase_skill",
      "repo_slot_phase_prompt",
      "repo_slot_phase_skill"
    )
    expect(project_prompt.fetch("layers").map { |layer| layer.fetch("title") }).to include(
      "prompts/implementation.md",
      "skills/common-testing.md",
      "ui_app:prompts/ui-implementation.md",
      "ui_app:skills/playwright.md"
    )
    metadata = described_class.new.project_prompt_metadata(request_form)
    expect(metadata.fetch("repo_slot")).to eq("ui_app")
    expect(metadata.fetch("repo_slots")).to eq(["ui_app"])
    expect(metadata.fetch("layers").map { |layer| layer.fetch("kind") }).to include("repo_slot_phase_prompt", "repo_slot_phase_skill")
  end

  it "composes repo-slot prompt addons from explicit repo_slots on multi-repo requests" do
    prompt_config = A3::Domain::ProjectPromptConfig.new(
      phases: {
        "implementation" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
          prompt_document: prompt_document("prompts/implementation.md", "implementation guidance")
        )
      },
      repo_slots: {
        "repo_alpha" => {
          "implementation" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
            skill_documents: [prompt_document("skills/repo-alpha.md", "repo alpha guidance")]
          )
        },
        "repo_beta" => {
          "implementation" => A3::Domain::ProjectPromptConfig::PhaseConfig.new(
            skill_documents: [prompt_document("skills/repo-beta.md", "repo beta guidance")]
          )
        }
      }
    )
    runtime = phase_runtime_with_prompt_config(prompt_config, phase: :implementation, repo_scope: :both, repo_slots: %i[repo_alpha repo_beta])
    multi_repo_packet = A3::Domain::WorkerTaskPacket.new(
      ref: task.ref,
      external_task_id: task.external_task_id,
      kind: task.kind,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      parent_ref: task.parent_ref,
      child_refs: task.child_refs,
      title: task_packet.title,
      description: task_packet.description,
      status: task_packet.status,
      labels: task_packet.labels
    )

    request_form = described_class.new.request_form(
      skill: runtime.implementation_skill,
      workspace: workspace,
      task: task,
      run: implementation_run,
      phase_runtime: runtime,
      task_packet: multi_repo_packet
    )

    project_prompt = request_form.fetch("phase_runtime").fetch("project_prompt")
    expect(project_prompt.fetch("composed_instruction")).to include("implementation guidance")
    expect(project_prompt.fetch("composed_instruction")).to include("repo alpha guidance")
    expect(project_prompt.fetch("composed_instruction")).to include("repo beta guidance")
    expect(project_prompt.fetch("repo_slot")).to be_nil
    expect(project_prompt.fetch("repo_slots")).to eq(%w[repo_alpha repo_beta])
    expect(project_prompt.fetch("layers").map { |layer| layer.fetch("title") }).to include(
      "repo_alpha:skills/repo-alpha.md",
      "repo_beta:skills/repo-beta.md"
    )

    metadata = described_class.new.project_prompt_metadata(request_form)
    expect(metadata.fetch("repo_slot")).to eq("")
    expect(metadata.fetch("repo_slots")).to eq(%w[repo_alpha repo_beta])
  end

  it "preserves existing worker request shape when no project prompts are configured" do
    request_form = described_class.new.request_form(
      skill: phase_runtime.review_skill,
      workspace: workspace,
      task: task,
      run: run,
      phase_runtime: phase_runtime,
      task_packet: task_packet
    )

    expect(request_form.fetch("phase_runtime")).not_to have_key("project_prompt")
  end

  it "accepts ordered slot scopes in review_disposition" do
    result = described_class.new(
      review_disposition_slot_scopes: %w[repo_alpha repo_beta]
    ).build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_alpha" => ["marker.txt"], "repo_beta" => ["marker.txt"] },
        "review_disposition" => {
          "kind" => "completed",
          "slot_scopes" => %w[repo_alpha repo_beta],
          "summary" => "self-review clean",
          "description" => "No findings.",
          "finding_key" => "none"
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_alpha" => ["marker.txt"], "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: true)
    expect(result.response_bundle.fetch("review_disposition").fetch("slot_scopes")).to eq(%w[repo_alpha repo_beta])
  end

  it "rejects label aliases in review_disposition slot_scopes" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_alpha" => ["marker.txt"], "repo_beta" => ["marker.txt"] },
        "review_disposition" => {
          "kind" => "completed",
          "slot_scopes" => ["repo:both"],
          "summary" => "self-review clean",
          "description" => "No findings.",
          "finding_key" => "none"
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_alpha" => ["marker.txt"], "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: false)
    expect(result.diagnostics.fetch("validation_errors")).to include("review_disposition.slot_scopes must be one of repo_beta")
  end

  it "requires review_disposition for implementation success" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_beta" => ["marker.txt"] }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: false)
    expect(result.summary).to eq("worker result schema invalid")
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "review_disposition must be present for implementation success"
    )
  end

  it "preserves structured docs-impact worker results" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_beta" => ["docs/shared/project-package-schema.md"] },
        "review_disposition" => {
          "kind" => "completed",
          "slot_scopes" => ["repo_beta"],
          "summary" => "self-review clean",
          "description" => "No findings.",
          "finding_key" => "none"
        },
        "docs_impact" => {
          "disposition" => "yes",
          "categories" => ["shared_specs"],
          "updated_docs" => ["docs/shared/project-package-schema.md"],
          "updated_authorities" => ["project.yaml schema"],
          "skipped_docs" => [
            { "path" => "docs/ja/shared/project-package-schema.md", "reason" => "mirror follow-up" }
          ],
          "matched_rules" => ["keyword:schema->shared_specs"],
          "review_disposition" => "accepted",
          "traceability" => {
            "related_tickets" => [task.ref]
          }
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_beta" => ["docs/shared/project-package-schema.md"] }
    )

    expect(result).to have_attributes(success?: true)
    expect(result.response_bundle.fetch("docs_impact")).to include(
      "disposition" => "yes",
      "updated_docs" => ["docs/shared/project-package-schema.md"]
    )
  end

  it "reports precise validation errors for invalid docs-impact worker results" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_beta" => ["marker.txt"] },
        "review_disposition" => {
          "kind" => "completed",
          "slot_scopes" => ["repo_beta"],
          "summary" => "self-review clean",
          "description" => "No findings.",
          "finding_key" => "none"
        },
        "docs_impact" => {
          "disposition" => "clean",
          "updated_docs" => [123],
          "skipped_docs" => [{ "path" => "docs/spec.md" }]
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: false)
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "docs_impact.disposition must be one of yes, no, maybe",
      "docs_impact.updated_docs must be an array of strings when present",
      "docs_impact.skipped_docs[0].reason must be a string"
    )
  end

  it "requires blocked docs-impact review findings to route child review to rework" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "review completed",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "docs_impact" => {
          "disposition" => "yes",
          "categories" => ["shared_specs"],
          "review_disposition" => "blocked",
          "matched_rules" => ["shared spec missing"]
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review,
      expected_task_kind: :child
    )

    expect(result).to have_attributes(success?: false)
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "docs_impact.review_disposition=blocked requires review result success=false",
      "docs_impact.review_disposition=blocked requires rework_required=true for child review"
    )
  end

  it "accepts non-blocking docs-impact review debt as structured evidence" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "review completed",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "docs_impact" => {
          "disposition" => "maybe",
          "categories" => ["features"],
          "review_disposition" => "warned",
          "matched_rules" => ["feature docs maybe needed"]
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review,
      expected_task_kind: :child
    )

    expect(result).to have_attributes(success?: true)
    expect(result.response_bundle.fetch("docs_impact").fetch("review_disposition")).to eq("warned")
  end

  it "rejects docs-impact follow-up disposition for child review" do
    result = described_class.new.build_execution_result(
      {
        "success" => true,
        "summary" => "review completed",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "docs_impact" => {
          "disposition" => "maybe",
          "categories" => ["features"],
          "review_disposition" => "follow_up",
          "matched_rules" => ["feature docs follow-up"]
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review,
      expected_task_kind: :child
    )

    expect(result).to have_attributes(success?: false)
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "docs_impact.review_disposition=follow_up is only supported for parent review"
    )
  end

  it "canonicalizes optional worker identity fields instead of blocking on invented refs" do
    result = described_class.new(review_disposition_slot_scopes: %w[repo_beta]).build_execution_result(
      {
        "success" => true,
        "summary" => "parent review completed",
        "task_ref" => "invented-task",
        "run_ref" => "invented-run",
        "phase" => "ProjectName-10-parent",
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "completed",
          "slot_scopes" => ["repo_beta"],
          "summary" => "No findings",
          "description" => "The parent integration branch is ready.",
          "finding_key" => "no-findings"
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review
    )

    expect(result).to have_attributes(success?: true)
    expect(result.response_bundle).to include(
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "review"
    )
    expect(result.diagnostics.fetch("canonicalized_identity")).to include(
      "task_ref" => hash_including("provided" => "invented-task", "canonical" => task.ref),
      "run_ref" => hash_including("provided" => "invented-run", "canonical" => run.ref),
      "phase" => hash_including("provided" => "ProjectName-10-parent", "canonical" => "review")
    )
  end

  it "normalizes parent review success without an explicit review_disposition" do
    result = described_class.new(review_disposition_slot_scopes: %w[repo_beta]).build_execution_result(
      {
        "success" => true,
        "summary" => "parent review completed",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review,
      expected_task_kind: :parent
    )

    expect(result).to have_attributes(success?: true)
    expect(result.response_bundle.fetch("review_disposition")).to eq(
      "kind" => "completed",
      "slot_scopes" => ["repo_beta"],
      "summary" => "parent review completed",
      "description" => "parent review completed",
      "finding_key" => "parent-review-completed"
    )
  end

  it "normalizes frozen parent review success payloads without mutating the worker response" do
    worker_response = {
      "success" => true,
      "summary" => "parent review completed",
      "task_ref" => task.ref,
      "run_ref" => run.ref,
      "phase" => "review",
      "rework_required" => false,
      "changed_files" => {
        "repo_beta" => ["marker.txt"].freeze
      }.freeze
    }.freeze

    result = described_class.new(review_disposition_slot_scopes: %w[repo_beta]).build_execution_result(
      worker_response,
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review,
      expected_task_kind: :parent
    )

    expect(result).to have_attributes(success?: true)
    expect(result.response_bundle.fetch("review_disposition")).to include(
      "kind" => "completed",
      "slot_scopes" => ["repo_beta"],
      "finding_key" => "parent-review-completed"
    )
    expect(worker_response).not_to have_key("review_disposition")
  end

  it "accepts a clarification request without blocked failure diagnostics" do
    result = described_class.new.build_execution_result(
      {
        "success" => false,
        "summary" => "permission model is ambiguous",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "clarification_request" => {
          "question" => "Should this bypass require admin approval?",
          "context" => "The ticket conflicts with the current permission model.",
          "options" => ["Require admin approval", "Keep the current model"],
          "recommended_option" => "Require admin approval",
          "impact" => "Scheduler waits until the requester answers."
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review
    )

    expect(result).to have_attributes(success?: false, failing_command: nil, observed_state: nil)
    expect(result.clarification_request).to have_attributes(
      question: "Should this bypass require admin approval?",
      options: ["Require admin approval", "Keep the current model"]
    )
  end

  it "rejects malformed clarification requests" do
    result = described_class.new.build_execution_result(
      {
        "success" => false,
        "summary" => "ambiguous",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "clarification_request" => {
          "question" => " ",
          "options" => ["valid", ""]
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review
    )

    expect(result.summary).to eq("worker result schema invalid")
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "clarification_request.question must be a non-empty string",
      "clarification_request.options must be an array of non-empty strings"
    )
  end

  it "accepts and normalizes structured skill feedback without changing successful worker flow" do
    result = described_class.new(
      repo_scope_aliases: { "repo:both" => "both" },
      review_disposition_slot_scopes: %w[repo_alpha repo_beta]
    ).build_execution_result(
      {
        "success" => true,
        "summary" => "worker completed",
        "task_ref" => task.ref,
        "run_ref" => implementation_run.ref,
        "phase" => "implementation",
        "rework_required" => false,
        "changed_files" => { "repo_beta" => ["marker.txt"] },
        "review_disposition" => {
          "kind" => "completed",
          "slot_scopes" => ["repo_beta"],
          "summary" => "self-review clean",
          "description" => "No findings.",
          "finding_key" => "none"
        },
        "skill_feedback" => {
          "schema" => "a2o-skill-feedback/v1",
          "category" => "missing_context",
          "summary" => "Add fixture update guidance before verification.",
          "repo_scope" => "repo:both",
          "skill_path" => "skills/implementation/base.md",
          "proposal" => {
            "target" => "project_skill",
            "suggested_patch" => "Check fixture update command before running verification."
          },
          "confidence" => "medium"
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: implementation_run.ref,
      expected_phase: :implementation,
      canonical_changed_files: { "repo_beta" => ["marker.txt"] }
    )

    expect(result).to have_attributes(success?: true)
    expect(result.skill_feedback.first).to include(
      "category" => "missing_context",
      "repo_scope" => "both",
      "summary" => "Add fixture update guidance before verification."
    )
  end

  it "rejects malformed skill feedback when present" do
    result = described_class.new.build_execution_result(
      {
        "success" => false,
        "summary" => "worker failed",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "failing_command" => "review_worker",
        "observed_state" => "invalid feedback",
        "skill_feedback" => {
          "category" => "missing_context",
          "proposal" => {}
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review
    )

    expect(result).to have_attributes(success?: false)
    expect(result.summary).to eq("worker result schema invalid")
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "skill_feedback[0].summary must be a string",
      "skill_feedback[0].proposal.target must be a string"
    )
    expect(result.skill_feedback).to eq([])
  end

  it "rejects unknown skill feedback targets" do
    result = described_class.new.build_execution_result(
      {
        "success" => false,
        "summary" => "worker failed",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "failing_command" => "review_worker",
        "observed_state" => "invalid feedback",
        "skill_feedback" => {
          "category" => "missing_context",
          "summary" => "target has a typo",
          "proposal" => { "target" => "project_skll" }
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review
    )

    expect(result).to have_attributes(success?: false)
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "skill_feedback[0].proposal.target must be one of project_skill, a2o_preset, unknown"
    )
    expect(result.skill_feedback).to eq([])
  end

  it "rejects unknown skill feedback lifecycle states" do
    result = described_class.new.build_execution_result(
      {
        "success" => false,
        "summary" => "worker failed",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "failing_command" => "review_worker",
        "observed_state" => "invalid feedback",
        "skill_feedback" => {
          "category" => "missing_context",
          "summary" => "state has a typo",
          "state" => "converted",
          "proposal" => { "target" => "project_skill" }
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review
    )

    expect(result).to have_attributes(success?: false)
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "skill_feedback[0].state must be one of new, accepted, rejected, converted_to_ticket, applied"
    )
    expect(result.skill_feedback).to eq([])
  end

  it "rejects parent review success with follow-up child disposition" do
    result = described_class.new(review_disposition_slot_scopes: %w[repo_beta]).build_execution_result(
      {
        "success" => true,
        "summary" => "follow-up required",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "follow_up_child",
          "slot_scopes" => ["repo_beta"],
          "summary" => "follow-up required",
          "description" => "Reviewer found work for a child task.",
          "finding_key" => "follow-up-1"
        }
      },
      workspace: workspace,
      expected_task_ref: task.ref,
      expected_run_ref: run.ref,
      expected_phase: :review
    )

    expect(result).to have_attributes(success?: false)
    expect(result.summary).to eq("worker result schema invalid")
    expect(result.diagnostics.fetch("validation_errors")).to include(
      "review_disposition.kind must be completed when success is true for parent review"
    )
  end

  def implementation_run
    A3::Domain::Run.new(
      ref: "run-implementation-1",
      task_ref: task.ref,
      phase: :implementation,
      workspace_kind: :runtime_workspace,
      source_descriptor: source_descriptor,
      scope_snapshot: A3::Domain::ScopeSnapshot.new(
        edit_scope: [:repo_alpha, :repo_beta],
        verification_scope: [:repo_alpha, :repo_beta],
        ownership_scope: :task
      ),
      artifact_owner: A3::Domain::ArtifactOwner.new(
        owner_ref: task.ref,
        owner_scope: :task,
        snapshot_version: "head-1"
      )
    )
  end

  def source_descriptor
    A3::Domain::SourceDescriptor.runtime_detached_commit(task_ref: task.ref, ref: "abc123")
  end

  def prompt_document(path, content)
    A3::Domain::ProjectPromptConfig::Document.new(
      path: path,
      absolute_path: File.join(tmpdir, path),
      content: content
    )
  end

  def phase_runtime_with_prompt_config(prompt_config, phase: :review, repo_scope: :ui_app, repo_slots: nil)
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: repo_scope,
      repo_slots: repo_slots,
      phase: phase,
      implementation_skill: "task implementation",
      review_skill: "task review",
      verification_commands: [],
      remediation_commands: [],
      workspace_hook: "bootstrap",
      merge_target: :merge_to_parent,
      merge_policy: :squash,
      project_prompt_config: prompt_config
    )
  end
end
