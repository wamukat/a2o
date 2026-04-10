# frozen_string_literal: true

RSpec.describe A3::Domain::Task do
  describe "#supports_phase?" do
    it "does not allow implementation for parent tasks" do
      task = described_class.new(
        ref: "A3-v2#3022",
        kind: :parent,
        edit_scope: [:repo_beta, :repo_alpha]
      )

      expect(task.supports_phase?(:implementation)).to be(false)
      expect(task.supports_phase?(:review)).to be(true)
    end

    it "allows implementation for child tasks" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha]
      )

      expect(task.supports_phase?(:implementation)).to be(true)
      expect(task.supports_phase?(:review)).to be(false)
    end

    it "keeps review support for legacy child tasks already in review" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :in_review
      )

      expect(task.supports_phase?(:review)).to be(true)
    end
  end

  describe "#next_phase_for" do
    it "returns verification after child implementation" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha]
      )

      expect(task.next_phase_for(:implementation)).to eq(:verification)
    end

    it "returns verification after parent review" do
      task = described_class.new(
        ref: "A3-v2#3022",
        kind: :parent,
        edit_scope: [:repo_beta, :repo_alpha]
      )

      expect(task.next_phase_for(:review)).to eq(:verification)
    end

    it "returns nil for terminal merge" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha]
      )

      expect(task.next_phase_for(:merge)).to be_nil
    end
  end

  describe "#terminal_status_for" do
    it "returns blocked for blocked outcomes" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha]
      )

      expect(task.terminal_status_for(phase: :review, outcome: :blocked)).to eq(:blocked)
    end

    it "returns done for merge completion" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha]
      )

      expect(task.terminal_status_for(phase: :merge, outcome: :completed)).to eq(:done)
    end

    it "keeps the current status for retryable outcomes" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :in_progress
      )

      expect(task.terminal_status_for(phase: :implementation, outcome: :retryable)).to eq(:in_progress)
    end

    it "keeps the current status for terminal noop outcomes" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :merging
      )

      expect(task.terminal_status_for(phase: :merge, outcome: :terminal_noop)).to eq(:merging)
    end
  end

  describe "#start_run" do
    it "returns a new task with current run and status derived from the phase" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :in_review
      )

      updated = task.start_run("run-1", phase: :review)

      expect(updated).not_to equal(task)
      expect(updated.current_run_ref).to eq("run-1")
      expect(updated.status).to eq(:in_review)
      expect(task.current_run_ref).to be_nil
      expect(task.status).to eq(:in_review)
    end
  end

  describe "topology and scope" do
    it "keeps verification scope and parent-child refs as part of the aggregate" do
      task = described_class.new(
        ref: "A3-v2#3022",
        kind: :parent,
        edit_scope: [:repo_alpha],
        verification_scope: [:repo_alpha, :repo_beta],
        child_refs: ["A3-v2#3025", "A3-v2#3026"]
      )

      expect(task.verification_scope).to eq([:repo_alpha, :repo_beta])
      expect(task.child_refs).to eq(["A3-v2#3025", "A3-v2#3026"])
    end

    it "derives repo_scope both when multiple edit scopes exist" do
      task = described_class.new(
        ref: "A3-v2#3022",
        kind: :parent,
        edit_scope: [:repo_alpha, :repo_beta]
      )

      expect(task.repo_scope_key).to eq(:both)
    end
  end

  describe "#runnable_phase" do
    it "does not re-enter implementation for parent tasks that somehow hold in_progress" do
      task = described_class.new(
        ref: "Portal#3140",
        kind: :parent,
        edit_scope: %i[repo_alpha repo_beta],
        status: :in_progress
      )

      expect(task.runnable_phase).to be_nil
    end
  end

  describe "#complete_run" do
    it "moves to the next phase status and clears current run ref" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :in_progress,
        current_run_ref: "run-1"
      )

      updated = task.complete_run(next_phase: :verification, terminal_status: nil)

      expect(updated.status).to eq(:verifying)
      expect(updated.current_run_ref).to be_nil
      expect(task.current_run_ref).to eq("run-1")
    end

    it "moves to terminal status when no next phase exists" do
      task = described_class.new(
        ref: "A3-v2#3025",
        kind: :child,
        edit_scope: [:repo_alpha],
        status: :merging,
        current_run_ref: "run-1"
      )

      updated = task.complete_run(next_phase: nil, terminal_status: :done)

      expect(updated.status).to eq(:done)
      expect(updated.current_run_ref).to be_nil
    end
  end
end
