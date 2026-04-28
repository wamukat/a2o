# frozen_string_literal: true

RSpec.describe A3::CLI::ShowOutputFormatter::WatchSummaryFormatter do
  it "renders aligned phase headers and colorized task rows" do
    summary = Struct.new(:scheduler_paused, :scheduler_paused_at, :tasks, :next_candidates, :running_entries).new(
      false,
      nil,
      [
        Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
          "Sample#1",
          nil,
          "Parent task",
          :parent,
          false,
          false,
          true,
          false,
          false,
          nil,
          {},
          []
        ),
        Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
          "Sample#2",
          "Sample#1",
          "Blocked child",
          :child,
          true,
          false,
          false,
          false,
          false,
          "review",
          { "implementation" => 1, "review" => 1 },
          ["review blocked"]
        )
      ],
      ["Sample#1"],
      []
    )

    lines = described_class.lines(summary)

    expect(lines[0]).to include("\e[36mScheduler: idle version=#{A3::VERSION}\e[0m")
    expect(lines).to include("[_] idle     [.] waiting  |  . : none     |                  Merging -----------+")
    expect(lines).to include("[*] next     [>] running  |  > : running  |               Inspecting ---------+ |")
    expect(lines).to include("[o] done     [!] blocked  |  o : done     |                   Review -------+ | |")
    expect(lines).to include(a_string_including("x : failed"))
    expect(lines).to include(a_string_including("! : blocked"))
    expect(lines).to include("\e[36mTask Tree\e[0m")
    expect(lines).to include(a_string_including("\e[36m[*] #1"))
    expect(lines).to include(a_string_including("\e[31m[!]   #2"))
    expect(lines).to include(a_string_including("-/././."))
    expect(lines.join("\n")).not_to include("review blocked")
  end

  it "renders review rework as a failed review phase marker" do
    task = Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :phase_states, :blocked_lines).new(
      "Sample#2",
      nil,
      "Review rejected task",
      :single,
      false,
      false,
      false,
      false,
      false,
      "implementation",
      { "implementation" => 2, "review" => 1 },
      { "review" => :failed },
      []
    )
    summary = Struct.new(:scheduler_paused, :scheduler_paused_at, :tasks, :next_candidates, :running_entries).new(
      false,
      nil,
      [task],
      [],
      []
    )

    row = described_class.lines(summary).find { |line| line.include?("Review rejected task") }

    expect(row).to include("o/x/./.")
  end

  it "renders per-task detail lines only when details are requested" do
    task = Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
      "Sample#2",
      nil,
      "Blocked task",
      :single,
      true,
      false,
      false,
      false,
      false,
      "review",
      { "implementation" => 1, "review" => 1 },
      ["review blocked"]
    )
    summary = Struct.new(:scheduler_paused, :scheduler_paused_at, :tasks, :next_candidates, :running_entries).new(
      false,
      nil,
      [task],
      [],
      []
    )

    default_lines = described_class.lines(summary).join("\n")
    detailed_lines = described_class.lines(summary, details: true).join("\n")

    expect(default_lines).not_to include("review blocked")
    expect(detailed_lines).to include("review blocked")
  end

  it "indents child task refs when the parent is present" do
    summary = Struct.new(:scheduler_paused, :scheduler_paused_at, :tasks, :next_candidates, :running_entries).new(
      false,
      nil,
      [
        Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
          "Sample#51",
          nil,
          "Parent task",
          :parent,
          false,
          false,
          false,
          false,
          false,
          nil,
          {},
          []
        ),
        Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
          "Sample#52",
          "Sample#51",
          "Child task",
          :child,
          false,
          false,
          false,
          true,
          false,
          nil,
          {},
          []
        )
      ],
      [],
      []
    )

    child_line = described_class.lines(summary).find { |line| line.include?("#52") }

    expect(child_line).to include("[.]   #52")
  end

  it "shows review-phase tasks as running when running_entry is present" do
    running_entry = Struct.new(:task_ref, :phase, :internal_phase, :state, :heartbeat_age_seconds, :detail).new(
      "Sample#3141",
      "review",
      "review",
      "running_command",
      nil,
      "refs/heads/a2o/work/Sample-3141"
    )
    summary = Struct.new(:scheduler_paused, :scheduler_paused_at, :tasks, :next_candidates, :running_entries).new(
      false,
      nil,
      [
        Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
          "Sample#3141",
          nil,
          "Review task",
          :single,
          false,
          true,
          false,
          false,
          false,
          "review",
          { "implementation" => 1, "review" => 1 },
          []
        )
      ],
      [],
      [running_entry]
    )

    lines = described_class.lines(summary).join("\n")

    expect(lines).to include("o/>/./.")
    expect(lines).to include("- #3141 review/review/running_command hb=?")
  end

  it "uses ASCII task and phase symbols" do
    summary = Struct.new(:scheduler_paused, :scheduler_paused_at, :tasks, :next_candidates, :running_entries).new(
      false,
      nil,
      [
        Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
          "Sample#3141",
          nil,
          "Review task",
          :single,
          false,
          true,
          false,
          false,
          false,
          "review",
          { "implementation" => 1, "review" => 1 },
          []
        )
      ],
      [],
      []
    )

    lines = described_class.lines(summary)

    expect(lines.join("\n")).to include("o/>/./.")
    expect(lines.join("\n")).to include("[>] #3141")
    expect(lines).to include(a_string_matching(/Merging -+\+$/))
  end

  it "shows scheduler as running when a running entry exists" do
    running_entry = Struct.new(:task_ref, :phase, :internal_phase, :state, :heartbeat_age_seconds, :detail).new(
      "Sample#3141",
      "review",
      "review",
      "running_command",
      nil,
      nil
    )
    summary = Struct.new(:scheduler_paused, :scheduler_paused_at, :tasks, :next_candidates, :running_entries).new(
      false,
      nil,
      [],
      [],
      [running_entry]
    )

    expect(described_class.lines(summary).first).to include("\e[36mScheduler: running version=#{A3::VERSION}\e[0m")
  end

  it "does not indent orphan tasks whose parent is not present in the summary" do
    summary = Struct.new(:scheduler_paused, :scheduler_paused_at, :tasks, :next_candidates, :running_entries).new(
      false,
      nil,
      [
        Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
          "Sample#3179",
          nil,
          "Parent task",
          :single,
          false,
          true,
          false,
          false,
          false,
          "review",
          { "implementation" => 1, "review" => 1 },
          []
        ),
        Struct.new(:ref, :parent_ref, :title, :task_kind, :blocked, :running, :next_candidate, :waiting, :done, :latest_phase, :phase_counts, :blocked_lines).new(
          "Sample#3166",
          "Sample#3165",
          "Orphan child",
          :child,
          false,
          false,
          false,
          false,
          true,
          nil,
          {},
          []
        )
      ],
      [],
      []
    )

    lines = described_class.lines(summary)
    orphan_line = lines.find { |line| line.include?("#3166") }

    expect(orphan_line).to include("[o] #3166")
    expect(orphan_line).not_to include("[o]   #3166")
  end
end
