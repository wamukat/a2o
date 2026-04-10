# frozen_string_literal: true

RSpec.describe A3::Domain::PhasePolicy do
  subject(:policy) { described_class.new(task_kind: :child, current_status: :in_progress) }

  describe "#supports_phase?" do
    it "supports implementation for child tasks" do
      expect(policy.supports_phase?(:implementation)).to be(true)
    end

    it "does not support implementation for parent tasks" do
      parent_policy = described_class.new(task_kind: :parent, current_status: :in_review)

      expect(parent_policy.supports_phase?(:implementation)).to be(false)
    end
  end

  describe "#next_phase_for" do
    it "returns review after implementation" do
      expect(policy.next_phase_for(:implementation)).to eq(:review)
    end

    it "returns merge after verification for parent tasks" do
      parent_policy = described_class.new(task_kind: :parent, current_status: :verifying)

      expect(parent_policy.next_phase_for(:verification)).to eq(:merge)
    end
  end

  describe "#status_for_phase" do
    it "maps review to in_review" do
      expect(policy.status_for_phase(:review)).to eq(:in_review)
    end
  end

  describe "#display_phase_order" do
    it "collapses child tasks into implementation inspection merge" do
      expect(policy.display_phase_order).to eq(%i[implementation inspection merge])
    end

    it "keeps parent review as an external phase" do
      parent_policy = described_class.new(task_kind: :parent, current_status: :in_review)

      expect(parent_policy.display_phase_order).to eq(%i[review inspection merge])
    end
  end

  describe "#display_phase_for" do
    it "maps child review into implementation" do
      expect(policy.display_phase_for(:review)).to eq(:implementation)
    end

    it "maps verification into inspection" do
      expect(policy.display_phase_for(:verification)).to eq(:inspection)
    end

    it "keeps parent review visible" do
      parent_policy = described_class.new(task_kind: :parent, current_status: :in_review)

      expect(parent_policy.display_phase_for(:review)).to eq(:review)
    end
  end

  describe "#terminal_status_for" do
    it "returns blocked for blocked outcomes" do
      expect(policy.terminal_status_for(phase: :review, outcome: :blocked)).to eq(:blocked)
    end

    it "keeps the current status for retryable outcomes" do
      expect(policy.terminal_status_for(phase: :implementation, outcome: :retryable)).to eq(:in_progress)
    end

    it "returns done for completed merge" do
      merging_policy = described_class.new(task_kind: :child, current_status: :merging)

      expect(merging_policy.terminal_status_for(phase: :merge, outcome: :completed)).to eq(:done)
    end

    it "fails closed for parent rework outcomes" do
      parent_policy = described_class.new(task_kind: :parent, current_status: :in_review)

      expect(parent_policy.terminal_status_for(phase: :review, outcome: :rework)).to eq(:blocked)
    end
  end
end
