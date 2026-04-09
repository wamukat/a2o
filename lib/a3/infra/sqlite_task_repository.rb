# frozen_string_literal: true

require "fileutils"
require "sqlite3"

module A3
  module Infra
    class SqliteTaskRepository
      include A3::Domain::TaskRepository

      def initialize(path)
        @path = path
        ensure_schema!
      end

      def save(task)
        db.execute(
          "INSERT INTO tasks (ref, payload) VALUES (?, ?) ON CONFLICT(ref) DO UPDATE SET payload = excluded.payload",
          [task.ref, JSON.generate(A3::Adapters::TaskRecord.dump(task))]
        )
      end

      def fetch(task_ref)
        row = db.get_first_row("SELECT payload FROM tasks WHERE ref = ?", [task_ref])
        raise A3::Domain::RecordNotFound, "Task not found: #{task_ref}" unless row

        A3::Adapters::TaskRecord.load(JSON.parse(row.fetch(0)))
      end

      def all
        db.execute("SELECT payload FROM tasks ORDER BY ref ASC").map do |row|
          A3::Adapters::TaskRecord.load(JSON.parse(row.fetch(0)))
        end.freeze
      end

      def delete(task_ref)
        db.execute("DELETE FROM tasks WHERE ref = ?", [task_ref])
      end

      private

      def ensure_schema!
        FileUtils.mkdir_p(File.dirname(@path))
        db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS tasks (
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
