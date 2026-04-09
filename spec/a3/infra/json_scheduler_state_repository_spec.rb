# frozen_string_literal: true

require "tmpdir"

RSpec.describe A3::Infra::JsonSchedulerStateRepository do
  it "round-trips scheduler state" do
    Dir.mktmpdir do |dir|
      repository = described_class.new(File.join(dir, "scheduler_state.json"))
      state = A3::Domain::SchedulerState.new(paused: true, last_stop_reason: :idle, last_executed_count: 3)

      repository.save(state)

      expect(repository.fetch).to eq(state)
    end
  end
end
