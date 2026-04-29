# frozen_string_literal: true

RSpec.describe A3::Domain::PhaseExecutionRecord do
  it "serializes and restores the execution observation" do
    record = described_class.new(
      summary: "commands/verify-all ok",
      failing_command: "commands/verify-all",
      observed_state: "exit 0",
      diagnostics: { "stdout" => "ok" },
      runtime_snapshot: A3::Domain::PhaseRuntimeSnapshot.new(
        task_kind: :child,
        repo_scope: :ui_app,
        phase: :review,
        implementation_skill: "sample-implementation",
        review_skill: "sample-review",
        verification_commands: ["commands/check-style", "commands/verify-all"],
        remediation_commands: ["commands/apply-remediation"],
        workspace_hook: "sample-bootstrap",
        merge_target: :merge_to_parent,
        merge_policy: :ff_only
      )
    )

    expect(record.persisted_form).to eq(
      "summary" => "commands/verify-all ok",
      "failing_command" => "commands/verify-all",
      "observed_state" => "exit 0",
      "diagnostics" => { "stdout" => "ok" },
      "review_disposition" => nil,
      "clarification_request" => nil,
      "skill_feedback" => [],
      "docs_impact" => nil,
      "follow_up_child_fingerprints" => [],
      "runtime_snapshot" => {
        "task_kind" => "child",
        "repo_scope" => "ui_app",
        "phase" => "review",
        "implementation_skill" => "sample-implementation",
        "review_skill" => "sample-review",
        "verification_commands" => ["commands/check-style", "commands/verify-all"],
        "remediation_commands" => ["commands/apply-remediation"],
        "metrics_collection_commands" => [],
        "notifications" => {
          "failure_policy" => "best_effort",
          "hooks" => []
        },
        "workspace_hook" => "sample-bootstrap",
        "merge_target" => "merge_to_parent",
        "merge_policy" => "ff_only",
        "review_gate_required" => false
      }
    )
    expect(described_class.from_persisted_form(record.persisted_form)).to eq(record)
  end

  it "deep-freezes nested diagnostics payloads" do
    nested = { "worker_response_bundle" => { "diagnostics" => { "stderr" => ["boom"] } } }
    record = described_class.new(summary: "blocked", diagnostics: nested)

    expect do
      record.diagnostics.fetch("worker_response_bundle").fetch("diagnostics")["stderr"] << "again"
    end.to raise_error(FrozenError)
  end

  it "captures review disposition from an execution result" do
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "implemented with self-review",
      response_bundle: {
        "review_disposition" => {
          "kind" => "completed",
          "repo_scope" => "repo_alpha",
          "summary" => "No findings",
          "description" => "Implementation finished and final self-review found no outstanding issues.",
          "finding_key" => "completed-no-findings"
        }
      }
    )

    record = described_class.from_execution_result(execution)

    expect(record.review_disposition).to eq(
      "kind" => "completed",
      "repo_scope" => "repo_alpha",
      "summary" => "No findings",
      "description" => "Implementation finished and final self-review found no outstanding issues.",
      "finding_key" => "completed-no-findings"
    )
  end

  it "captures skill feedback from an execution result" do
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "implemented with feedback",
      response_bundle: {
        "skill_feedback" => {
          "category" => "missing_context",
          "summary" => "Record fixture update workflow in the project skill.",
          "proposal" => {
            "target" => "project_skill",
            "suggested_patch" => "Run fixture update before verification."
          }
        }
      }
    )

    record = described_class.from_execution_result(execution)

    expect(record.skill_feedback).to eq([
      {
        "category" => "missing_context",
        "summary" => "Record fixture update workflow in the project skill.",
        "proposal" => {
          "target" => "project_skill",
          "suggested_patch" => "Run fixture update before verification."
        }
      }
    ])
    expect(described_class.from_persisted_form(record.persisted_form)).to eq(record)
  end

  it "captures clarification requests from an execution result" do
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "needs requester input",
      response_bundle: {
        "clarification_request" => {
          "question" => "Which option should be implemented?",
          "context" => "The acceptance criteria conflict.",
          "options" => ["Option A", "Option B"],
          "recommended_option" => "Option A",
          "impact" => "Runtime waits for requester input."
        }
      }
    )

    record = described_class.from_execution_result(execution)

    expect(record.clarification_request).to eq(
      "question" => "Which option should be implemented?",
      "context" => "The acceptance criteria conflict.",
      "options" => ["Option A", "Option B"],
      "recommended_option" => "Option A",
      "impact" => "Runtime waits for requester input."
    )
    expect(described_class.from_persisted_form(record.persisted_form)).to eq(record)
  end

  it "captures docs-impact evidence from an execution result" do
    execution = A3::Application::ExecutionResult.new(
      success: true,
      summary: "implemented with docs evidence",
      response_bundle: {
        "docs_impact" => {
          "disposition" => "yes",
          "categories" => ["shared_specs"],
          "updated_docs" => ["docs/shared/spec.md"],
          "matched_rules" => ["keyword:shared->shared_specs"]
        }
      }
    )

    record = described_class.from_execution_result(execution)

    expect(record.docs_impact).to eq(
      "disposition" => "yes",
      "categories" => ["shared_specs"],
      "updated_docs" => ["docs/shared/spec.md"],
      "matched_rules" => ["keyword:shared->shared_specs"]
    )
    expect(described_class.from_persisted_form(record.persisted_form)).to eq(record)
  end

  it "does not persist skill feedback from invalid worker results" do
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "worker result schema invalid",
      failing_command: "worker_result_schema",
      observed_state: "invalid_worker_result",
      response_bundle: {
        "skill_feedback" => {
          "category" => "missing_context",
          "summary" => "This rejected payload should not become evidence.",
          "proposal" => { "target" => "project_skill" }
        }
      }
    )

    record = described_class.from_execution_result(execution)

    expect(record.skill_feedback).to eq([])
  end

  it "does not persist docs-impact evidence from invalid worker results" do
    execution = A3::Application::ExecutionResult.new(
      success: false,
      summary: "worker result schema invalid",
      failing_command: "worker_result_schema",
      observed_state: "invalid_worker_result",
      response_bundle: {
        "docs_impact" => {
          "disposition" => "yes",
          "updated_docs" => ["docs/shared/spec.md"]
        }
      }
    )

    record = described_class.from_execution_result(execution)

    expect(record.docs_impact).to be_nil
  end
end
