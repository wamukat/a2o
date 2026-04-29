# frozen_string_literal: true

RSpec.describe A3::Domain::ProjectContext do
  let(:surface) do
    A3::Domain::ProjectSurface.new(
      implementation_skill: "skills/implementation/base.md",
      review_skill: {
        "default" => "skills/review/default.md",
        "variants" => {
          "task_kind" => {
            "parent" => {
              "repo_scope" => {
                "repo_alpha" => {
                  "phase" => {
                    "review" => "skills/review/repo-alpha-parent.md"
                  }
                }
              }
            }
          }
        }
      },
      verification_commands: ["commands/verify-all"],
      remediation_commands: ["commands/apply-remediation"],
      workspace_hook: "hooks/prepare-runtime.sh"
    )
  end

  let(:context) do
    described_class.new(
      surface: surface,
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only,
        target_ref: "refs/heads/live"
      )
    )
  end

  it "resolves phase runtime config for a parent review" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      child_refs: ["A3-v2#3030"]
    )

    runtime = context.resolve_phase_runtime(task: task, phase: :review)

    expect(runtime.task_kind).to eq(:parent)
    expect(runtime.repo_scope).to eq(:both)
    expect(runtime.phase).to eq(:review)
    expect(runtime.implementation_skill).to eq("skills/implementation/base.md")
    expect(runtime.review_skill).to eq("skills/review/default.md")
    expect(runtime.merge_target).to eq(:merge_to_parent)
    expect(runtime.merge_policy).to eq(:ff_only)
    expect(runtime.merge_target_ref).to eq("refs/heads/live")
  end

  it "builds a worker request payload from the resolved phase runtime config" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      verification_scope: %i[repo_alpha repo_beta],
      child_refs: ["A3-v2#3030"]
    )

    runtime = context.resolve_phase_runtime(task: task, phase: :review)

    expect(runtime.worker_request_form).to eq(
      "task_kind" => "parent",
      "repo_scope" => "both",
      "phase" => "review",
      "workspace_hook" => "hooks/prepare-runtime.sh",
      "implementation_skill" => "skills/implementation/base.md",
      "review_skill" => "skills/review/default.md",
      "verification_commands" => ["commands/verify-all"],
      "remediation_commands" => ["commands/apply-remediation"],
      "metrics_collection_commands" => [],
      "notifications" => {
        "failure_policy" => "best_effort",
        "hooks" => []
      },
      "merge_target" => "merge_to_parent",
      "merge_policy" => "ff_only",
      "merge_target_ref" => "refs/heads/live",
      "review_gate_required" => false,
      "docs_configured" => false
    )
  end

  it "uses task labels to override review gate policy" do
    context = described_class.new(
      surface: surface,
      merge_config: A3::Domain::MergeConfig.new(
        target: :merge_to_parent,
        policy: :ff_only,
        target_ref: "refs/heads/live"
      ),
      review_gate: {
        child: true,
        single: false,
        skip_labels: ["review:light"],
        require_labels: ["review:formal"]
      }
    )
    light_child = A3::Domain::Task.new(ref: "A3-v2#3030", kind: :child, edit_scope: [:repo_alpha], labels: ["review:light"])
    formal_single = A3::Domain::Task.new(ref: "A3-v2#3031", kind: :single, edit_scope: [:repo_alpha], labels: ["review:formal"])

    expect(context.resolve_phase_runtime(task: light_child, phase: :implementation).review_gate_required).to be(false)
    expect(context.resolve_phase_runtime(task: formal_single, phase: :implementation).review_gate_required).to be(true)
  end

  it "uses a task-kind-specific merge config resolver when present" do
    resolver = A3::Domain::MergeConfigResolver.new(
      policy_spec: "ff_only",
      target_ref_spec: {
        "default" => "refs/heads/live",
        "variants" => {
          "task_kind" => {
            "child" => {"default" => "refs/heads/a2o/parent/A3-v2-3022"}
          }
        }
      }
    )
    context = described_class.new(
      surface: surface,
      merge_config: resolver.default_merge_config,
      merge_config_resolver: resolver
    )
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: %i[repo_alpha repo_beta],
      parent_ref: "A3-v2#3022"
    )

    runtime = context.resolve_phase_runtime(task: task, phase: :merge)

    expect(runtime.merge_target).to eq(:merge_to_parent)
    expect(runtime.merge_target_ref).to eq("refs/heads/a2o/parent/A3-v2-3022")
    expect(context.merge_config.target).to eq(:merge_to_live)
  end
end
