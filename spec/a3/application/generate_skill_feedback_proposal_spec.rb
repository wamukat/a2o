# frozen_string_literal: true

RSpec.describe A3::Application::GenerateSkillFeedbackProposal do
  Entry = A3::Application::ListSkillFeedback::Entry

  it "generates a ticket-ready proposal from skill feedback entries" do
    list = instance_double(A3::Application::ListSkillFeedback)
    allow(list).to receive(:call).with(state: "new", target: nil).and_return([
      Entry.new(
        task_ref: "A2O#205",
        run_ref: "run-1",
        phase: :review,
        category: "missing_context",
        summary: "Add fixture setup guidance.",
        target: "project_skill",
        skill_path: "skills/review/default.md",
        confidence: "medium",
        state: "new",
        suggested_patch: "Check fixture setup before review.",
        group_key: "same"
      ),
      Entry.new(
        task_ref: "A2O#206",
        run_ref: "run-2",
        phase: :review,
        category: "missing_context",
        summary: "Add fixture setup guidance.",
        target: "project_skill",
        skill_path: "skills/review/default.md",
        confidence: "medium",
        state: "new",
        suggested_patch: "Check fixture setup before review.",
        group_key: "same"
      )
    ])

    result = described_class.new(list_skill_feedback: list).call

    expect(result).to include("# Skill feedback adoption proposal")
    expect(result).to include("- Add fixture setup guidance.")
    expect(result).to include("  - count: 2")
    expect(result).to include("  - source: A2O#205/run-1/review, A2O#206/run-2/review")
    expect(result).to include("review draft only")
  end

  it "generates a reviewed draft patch without applying it" do
    list = instance_double(A3::Application::ListSkillFeedback)
    allow(list).to receive(:call).with(state: "accepted", target: "project_skill").and_return([
      Entry.new(
        task_ref: "A2O#210",
        run_ref: "run-1",
        phase: :implementation,
        summary: "Capture review checklist.",
        target: "project_skill",
        skill_path: "skills/implementation/base.md",
        state: "accepted",
        suggested_patch: "Add review checklist before Done.",
        group_key: "patch"
      )
    ])

    result = described_class.new(list_skill_feedback: list).call(state: "accepted", target: "project_skill", format: :patch)

    expect(result).to include("# Draft skill patch")
    expect(result).to include("Review this draft before applying it.")
    expect(result).to include("## skills/implementation/base.md")
    expect(result).to include("Add review checklist before Done.")
  end

  it "makes an empty draft patch explicit when feedback has no suggested patch" do
    list = instance_double(A3::Application::ListSkillFeedback)
    allow(list).to receive(:call).with(state: "accepted", target: nil).and_return([
      Entry.new(
        task_ref: "A2O#210",
        run_ref: "run-1",
        phase: :implementation,
        summary: "Capture review checklist.",
        target: "project_skill",
        state: "accepted",
        group_key: "empty"
      )
    ])

    result = described_class.new(list_skill_feedback: list).call(state: "accepted", format: :patch)

    expect(result).to include("No suggested_patch values were present")
  end
end
