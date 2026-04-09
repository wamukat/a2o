# frozen_string_literal: true

RSpec.describe A3::Application::BuildScopeSnapshot do
  subject(:use_case) { described_class.new }

  it "uses task verification_scope instead of collapsing it to edit_scope" do
    task = A3::Domain::Task.new(
      ref: "A3-v2#3025",
      kind: :child,
      edit_scope: [:repo_alpha],
      verification_scope: [:repo_alpha, :repo_beta]
    )

    snapshot = use_case.call(task: task)

    expect(snapshot.edit_scope).to eq([:repo_alpha])
    expect(snapshot.verification_scope).to eq([:repo_alpha, :repo_beta])
  end
end
