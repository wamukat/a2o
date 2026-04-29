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

  it "normalizes project repo labels in review_disposition repo_scope" do
    result = described_class.new(
      repo_scope_aliases: { "repo:both" => "both" },
      review_disposition_repo_scopes: %w[repo_alpha repo_beta both]
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
          "repo_scope" => "repo:both",
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
    expect(result.response_bundle.fetch("review_disposition").fetch("repo_scope")).to eq("both")
  end

  it "does not hardcode project repo labels when normalizing review_disposition repo_scope" do
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
          "repo_scope" => "repo:both",
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
    expect(result.diagnostics.fetch("validation_errors")).to include("review_disposition.repo_scope must be one of repo_beta")
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

  it "canonicalizes optional worker identity fields instead of blocking on invented refs" do
    result = described_class.new(review_disposition_repo_scopes: %w[repo_beta]).build_execution_result(
      {
        "success" => true,
        "summary" => "parent review completed",
        "task_ref" => "invented-task",
        "run_ref" => "invented-run",
        "phase" => "ProjectName-10-parent",
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "completed",
          "repo_scope" => "repo_beta",
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
    result = described_class.new(review_disposition_repo_scopes: %w[repo_beta]).build_execution_result(
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
      "repo_scope" => "repo_beta",
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

    result = described_class.new(review_disposition_repo_scopes: %w[repo_beta]).build_execution_result(
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
      "repo_scope" => "repo_beta",
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
      review_disposition_repo_scopes: %w[repo_alpha repo_beta both]
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
          "repo_scope" => "repo_beta",
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
    result = described_class.new(review_disposition_repo_scopes: %w[repo_beta]).build_execution_result(
      {
        "success" => true,
        "summary" => "follow-up required",
        "task_ref" => task.ref,
        "run_ref" => run.ref,
        "phase" => "review",
        "rework_required" => false,
        "review_disposition" => {
          "kind" => "follow_up_child",
          "repo_scope" => "repo_beta",
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

  def phase_runtime_with_prompt_config(prompt_config, phase: :review)
    A3::Domain::PhaseRuntimeConfig.new(
      task_kind: :child,
      repo_scope: :ui_app,
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
