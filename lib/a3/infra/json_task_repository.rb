# frozen_string_literal: true

require "json"
require "fileutils"
require "tempfile"

module A3
  module Infra
    class JsonTaskRepository
      include A3::Domain::TaskRepository

      def initialize(path)
        @path = path
      end

      def save(task)
        with_records_lock do
          records = load_records
          records[task.ref] = A3::Adapters::TaskRecord.dump(task)
          write_records(records)
        end
      end

      def fetch(task_ref)
        record = with_records_lock { load_records.fetch(task_ref) }
        A3::Adapters::TaskRecord.load(record)
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Task not found: #{task_ref}"
      end

      def all
        with_records_lock do
          load_records
            .values
            .map { |record| A3::Adapters::TaskRecord.load(record) }
            .sort_by(&:ref)
            .freeze
        end
      end

      def delete(task_ref)
        with_records_lock do
          records = load_records
          records.delete(task_ref)
          write_records(records)
        end
      end

      private

      def with_records_lock
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      def lock_path
        "#{@path}.lock"
      end

      def load_records
        return {} unless File.exist?(@path)

        JSON.parse(File.read(@path))
      end

      def write_records(records)
        FileUtils.mkdir_p(File.dirname(@path))
        temp_path = nil
        Tempfile.create([File.basename(@path), ".tmp"], File.dirname(@path)) do |file|
          temp_path = file.path
          file.write(JSON.pretty_generate(records))
          file.flush
          file.fsync
          file.close
          File.rename(temp_path, @path)
          temp_path = nil
        end
      ensure
        FileUtils.rm_f(temp_path) if temp_path && File.exist?(temp_path)
      end
    end
  end
end
