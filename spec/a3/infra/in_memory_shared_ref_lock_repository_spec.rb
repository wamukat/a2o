# frozen_string_literal: true

RSpec.describe A3::Infra::InMemorySharedRefLockRepository do
  it "atomically allows only one concurrent holder for the same shared ref" do
    counter = 0
    repository = described_class.new(lock_ref_generator: -> { counter += 1; "lock-#{counter}" })
    ready = Queue.new
    start = Queue.new
    results = Queue.new

    threads = 8.times.map do |index|
      Thread.new do
        ready << true
        start.pop
        begin
          lock = repository.acquire(
            operation: :publish,
            repo_slot: :repo_beta,
            target_ref: "refs/heads/a2o/work/Sample-42",
            run_ref: "run-#{index}",
            claimed_at: "2026-04-30T00:00:00Z"
          )
          results << [:acquired, lock.lock_ref]
        rescue A3::Domain::SharedRefLockConflict => e
          results << [:conflict, e.holder_ref]
        end
      end
    end

    8.times { ready.pop }
    8.times { start << true }
    threads.each(&:join)
    outcomes = 8.times.map { results.pop }

    expect(outcomes.count { |status, _| status == :acquired }).to eq(1)
    expect(outcomes.count { |status, _| status == :conflict }).to eq(7)
    expect(repository.active_locks.size).to eq(1)
  end
end
