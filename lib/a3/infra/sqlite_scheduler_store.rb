# frozen_string_literal: true

require "fileutils"
require "json"
require "sqlite3"
require "a3/adapters/scheduler_state_record"
require "a3/adapters/scheduler_cycle_record"

module A3
  module Infra
    class SqliteSchedulerStore
      def initialize(path)
        @path = path
        ensure_schema!
      end

      def fetch_state
        row = db.get_first_row("SELECT payload FROM scheduler_state WHERE id = 1")
        return A3::Domain::SchedulerState.new unless row

        A3::Adapters::SchedulerStateRecord.load(JSON.parse(row.fetch(0)))
      end

      def save_state(state)
        db.execute(
          "INSERT INTO scheduler_state (id, payload) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
          [JSON.generate(A3::Adapters::SchedulerStateRecord.dump(state))]
        )
      end

      def all_cycles
        db.execute("SELECT payload FROM scheduler_cycles ORDER BY cycle_number ASC").map do |row|
          A3::Adapters::SchedulerCycleRecord.load(JSON.parse(row.fetch(0)))
        end
      end

      def append_cycle(cycle)
        stored_cycle = cycle.cycle_number ? cycle : cycle.with_cycle_number(next_cycle_number)
        insert_cycle(stored_cycle)
        stored_cycle
      end

      def record_cycle_result(next_state:, cycle:)
        stored_cycle = cycle.cycle_number ? cycle : cycle.with_cycle_number(next_cycle_number)
        db.transaction
        save_state(next_state)
        insert_cycle(stored_cycle)
        db.commit
        stored_cycle
      rescue StandardError
        db.rollback rescue nil
        raise
      end

      private

      def ensure_schema!
        FileUtils.mkdir_p(File.dirname(@path))
        db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS scheduler_state (
            id INTEGER PRIMARY KEY,
            payload TEXT NOT NULL
          )
        SQL
        db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS scheduler_cycles (
            cycle_number INTEGER PRIMARY KEY,
            payload TEXT NOT NULL
          )
        SQL
      end

      def insert_cycle(cycle)
        db.execute(
          "INSERT INTO scheduler_cycles (cycle_number, payload) VALUES (?, ?)",
          [cycle.cycle_number, JSON.generate(A3::Adapters::SchedulerCycleRecord.dump(cycle))]
        )
      end

      def next_cycle_number
        row = db.get_first_row("SELECT COALESCE(MAX(cycle_number), 0) + 1 FROM scheduler_cycles")
        Integer(row.fetch(0))
      end

      def db
        @db ||= SQLite3::Database.new(@path)
      end
    end
  end
end
