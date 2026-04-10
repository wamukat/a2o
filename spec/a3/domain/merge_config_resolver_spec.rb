# frozen_string_literal: true

RSpec.describe A3::Domain::MergeConfigResolver do
  subject(:resolver) do
    described_class.new(
      target_spec: {
        "default" => "merge_to_live",
        "variants" => {
          "task_kind" => {
            "child" => {
              "default" => "merge_to_parent"
            },
            "parent" => {
              "default" => "merge_to_live"
            }
          }
        }
      },
      policy_spec: {
        "default" => "ff_or_merge",
        "variants" => {
          "task_kind" => {
            "child" => {
              "default" => "ff_or_merge"
            }
          }
        }
      },
      target_ref_spec: {
        "default" => "refs/heads/live",
        "variants" => {
          "task_kind" => {
            "parent" => {
              "default" => "refs/heads/feature/prototype"
            }
          }
        }
      }
    )
  end

  it "exposes a default merge config for standalone tasks" do
    expect(resolver.default_merge_config).to eq(
      A3::Domain::MergeConfig.new(target: :merge_to_live, policy: :ff_or_merge, target_ref: "refs/heads/live")
    )
  end

  it "resolves merge_to_parent for child tasks" do
    child_task = A3::Domain::Task.new(
      ref: "A3-v2#3037",
      kind: :child,
      edit_scope: [:repo_beta],
      parent_ref: "A3-v2#3036"
    )

    expect(resolver.resolve(task: child_task, phase: :merge)).to eq(
      A3::Domain::MergeConfig.new(target: :merge_to_parent, policy: :ff_or_merge, target_ref: "refs/heads/live")
    )
  end

  it "resolves merge_to_live for parent tasks" do
    parent_task = A3::Domain::Task.new(
      ref: "A3-v2#3036",
      kind: :parent,
      edit_scope: %i[repo_alpha repo_beta],
      child_refs: %w[A3-v2#3037 A3-v2#3038]
    )

    expect(resolver.resolve(task: parent_task, phase: :merge)).to eq(
      A3::Domain::MergeConfig.new(target: :merge_to_live, policy: :ff_or_merge, target_ref: "refs/heads/feature/prototype")
    )
  end

  it "requires an explicit merge target ref specification" do
    expect do
      described_class.new(
        target_spec: "merge_to_live",
        policy_spec: "ff_only"
      )
    end.to raise_error(A3::Domain::ConfigurationError, /merge target ref must be provided/)
  end

  it "rejects a blank merge target ref specification" do
    expect do
      described_class.new(
        target_spec: "merge_to_live",
        policy_spec: "ff_only",
        target_ref_spec: "   "
      )
    end.to raise_error(A3::Domain::ConfigurationError, /merge target ref must not be blank/)
  end
end
