# frozen_string_literal: true

require "fileutils"
require "sqlite3"

module A3
  module Infra
    class SqliteRunRepository
      include A3::Domain::RunRepository

      def initialize(path)
        @path = path
        ensure_schema!
      end

      def save(run)
        db.execute(
          "INSERT INTO runs (ref, payload) VALUES (?, ?) ON CONFLICT(ref) DO UPDATE SET payload = excluded.payload",
          [run.ref, JSON.generate(A3::Adapters::RunRecord.dump(run))]
        )
      end

      def fetch(run_ref)
        row = db.get_first_row("SELECT payload FROM runs WHERE ref = ?", [run_ref])
        raise A3::Domain::RecordNotFound, "Run not found: #{run_ref}" unless row

        A3::Adapters::RunRecord.load(JSON.parse(row.fetch(0)))
      end

      def all
        db.execute("SELECT payload FROM runs ORDER BY rowid ASC").map do |row|
          A3::Adapters::RunRecord.load(JSON.parse(row.fetch(0)))
        end.freeze
      end

      private

      def ensure_schema!
        FileUtils.mkdir_p(File.dirname(@path))
        db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS runs (
            ref TEXT PRIMARY KEY,
            payload TEXT NOT NULL
          )
        SQL
      end

      def db
        @db ||= SQLite3::Database.new(@path)
      end
    end
  end
end
