# frozen_string_literal: true

require "json"
require "fileutils"

module A3
  module Infra
    class JsonTaskRepository
      include A3::Domain::TaskRepository

      def initialize(path)
        @path = path
      end

      def save(task)
        records = load_records
        records[task.ref] = A3::Adapters::TaskRecord.dump(task)
        write_records(records)
      end

      def fetch(task_ref)
        record = load_records.fetch(task_ref)
        A3::Adapters::TaskRecord.load(record)
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Task not found: #{task_ref}"
      end

      def all
        load_records
          .values
          .map { |record| A3::Adapters::TaskRecord.load(record) }
          .sort_by(&:ref)
          .freeze
      end

      def delete(task_ref)
        records = load_records
        records.delete(task_ref)
        write_records(records)
      end

      private

      def load_records
        return {} unless File.exist?(@path)

        JSON.parse(File.read(@path))
      end

      def write_records(records)
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate(records))
      end
    end
  end
end
