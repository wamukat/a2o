# frozen_string_literal: true

require "fileutils"
require "json"
require "sqlite3"

module A3
  module Infra
    class SqliteTaskMetricsRepository
      include A3::Domain::TaskMetricsRepository

      def initialize(path)
        @path = path
        ensure_schema!
      end

      def save(record)
        db.execute(
          "INSERT INTO task_metrics (task_ref, timestamp, payload) VALUES (?, ?, ?)",
          [record.task_ref, record.timestamp, JSON.generate(A3::Adapters::TaskMetricsRecord.dump(record))]
        )
      end

      def all
        db.execute("SELECT payload FROM task_metrics ORDER BY id ASC").map do |row|
          A3::Adapters::TaskMetricsRecord.load(JSON.parse(row.fetch(0)))
        end.freeze
      end

      private

      def ensure_schema!
        FileUtils.mkdir_p(File.dirname(@path))
        db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS task_metrics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_ref TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            payload TEXT NOT NULL
          )
        SQL
        db.execute "CREATE INDEX IF NOT EXISTS index_task_metrics_on_task_ref ON task_metrics (task_ref)"
      end

      def db
        @db ||= SQLite3::Database.new(@path)
      end
    end
  end
end
