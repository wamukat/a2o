# frozen_string_literal: true

RSpec.describe A3::Domain::PhasePolicy do
  subject(:policy) { described_class.new(task_kind: :child, current_status: :in_progress) }

  describe "#supports_phase?" do
    it "supports implementation for child tasks" do
      expect(policy.supports_phase?(:implementation)).to be(true)
    end

    it "does not treat child review as a canonical phase for fresh tasks" do
      expect(policy.supports_phase?(:review)).to be(false)
    end

    it "keeps child review runnable for legacy in_review tasks" do
      legacy_policy = described_class.new(task_kind: :child, current_status: :in_review)

      expect(legacy_policy.supports_phase?(:review)).to be(true)
    end

    it "does not support implementation for parent tasks" do
      parent_policy = described_class.new(task_kind: :parent, current_status: :in_review)

      expect(parent_policy.supports_phase?(:implementation)).to be(false)
    end
  end

  describe "#next_phase_for" do
    it "returns verification after implementation" do
      expect(policy.next_phase_for(:implementation)).to eq(:verification)
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
