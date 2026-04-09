# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::CLI do
  it "prints the next runnable child task while serializing siblings" do
    Dir.mktmpdir do |dir|
      task_repository = A3::Infra::SqliteTaskRepository.new(File.join(dir, "a3.sqlite3"))
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3020",
          kind: :child,
          edit_scope: [:repo_alpha],
          status: :in_progress,
          current_run_ref: "run-1",
          parent_ref: "A3-v2#3019"
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3021",
          kind: :child,
          edit_scope: [:repo_beta],
          status: :todo,
          parent_ref: "A3-v2#3019"
        )
      )
      task_repository.save(
        A3::Domain::Task.new(
          ref: "A3-v2#3030",
          kind: :single,
          edit_scope: [:repo_beta],
          status: :todo
        )
      )

      out = StringIO.new
      described_class.start(
        [
          "plan-next-runnable-task",
          "--storage-backend", "sqlite",
          "--storage-dir", dir
        ],
        out: out
      )

      expect(out.string).to include("next runnable A3-v2#3030 at implementation")
      expect(out.string).to include("selected_reason=runnable")
      expect(out.string).to include("assessment A3-v2#3021 reason=sibling_running blocked_by=A3-v2#3020")
    end
  end
end
