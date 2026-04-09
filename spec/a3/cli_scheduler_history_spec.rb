# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::CLI do
  it "shows scheduler cycle history through sqlite backend" do
    Dir.mktmpdir do |dir|
      repository = A3::Infra::SqliteSchedulerCycleRepository.new(File.join(dir, "a3.sqlite3"))
      repository.append(
        A3::Domain::SchedulerCycle.new(
          executed_count: 3,
          idle_reached: true,
          stop_reason: :idle,
          quarantined_count: 1
        )
      )

      out = StringIO.new
      described_class.start(
        ["show-scheduler-history", "--storage-backend", "sqlite", "--storage-dir", dir],
        out: out
      )

      expect(out.string).to include("cycle=1 executed=3 idle=true stop_reason=idle quarantined=1")
    end
  end
end
