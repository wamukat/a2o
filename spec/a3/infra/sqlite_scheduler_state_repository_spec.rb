# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::SqliteSchedulerStateRepository do
  it "round-trips scheduler state" do
    Dir.mktmpdir do |dir|
      repository = described_class.new(File.join(dir, "a3.sqlite3"))
      state = A3::Domain::SchedulerState.new(paused: true, last_stop_reason: :max_steps, last_executed_count: 2)

      repository.save(state)

      expect(repository.fetch).to eq(state)
    end
  end
end
