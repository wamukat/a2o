# frozen_string_literal: true

require "json"
require "fileutils"

module A3
  module Infra
    class JsonAgentJobStore
      def initialize(path)
        @path = path
      end

      def enqueue(request)
        with_records_lock do
          records = load_records
          raise A3::Domain::ConfigurationError, "agent job already exists: #{request.job_id}" if records.key?(request.job_id)

          record = A3::Domain::AgentJobRecord.new(request: request, state: :queued)
          records[request.job_id] = record.persisted_form
          write_records(records)
          record
        end
      end

      def claim_next(agent_name:, claimed_at:, project_key: nil)
        requested_project_key = project_key.to_s.strip
        with_records_lock do
          records = load_records
          job_id, record_payload = records.find do |_id, payload|
            record = A3::Domain::AgentJobRecord.from_persisted_form(payload)
            record.queued? && (requested_project_key.empty? || record.project_key == requested_project_key)
          end
          return nil unless job_id

          claimed = A3::Domain::AgentJobRecord.from_persisted_form(record_payload).claim(
            agent_name: agent_name,
            claimed_at: claimed_at
          )
          records[job_id] = claimed.persisted_form
          write_records(records)
          claimed
        end
      end

      def complete(result)
        with_records_lock do
          records = load_records
          record_payload = records.fetch(result.job_id) do
            raise A3::Domain::RecordNotFound, "Agent job not found: #{result.job_id}"
          end
          completed = A3::Domain::AgentJobRecord.from_persisted_form(record_payload).complete(result)
          records[result.job_id] = completed.persisted_form
          write_records(records)
          completed
        end
      end

      def heartbeat(job_id:, heartbeat_at:)
        with_records_lock do
          records = load_records
          record_payload = records.fetch(job_id) do
            raise A3::Domain::RecordNotFound, "Agent job not found: #{job_id}"
          end
          updated = A3::Domain::AgentJobRecord.from_persisted_form(record_payload).heartbeat(
            heartbeat_at: heartbeat_at
          )
          records[job_id] = updated.persisted_form
          write_records(records)
          updated
        end
      end

      def mark_stale(job_id:, reason:)
        with_records_lock do
          records = load_records
          record_payload = records.fetch(job_id) do
            raise A3::Domain::RecordNotFound, "Agent job not found: #{job_id}"
          end
          stale = A3::Domain::AgentJobRecord.from_persisted_form(record_payload).mark_stale(reason: reason)
          records[job_id] = stale.persisted_form
          write_records(records)
          stale
        end
      end

      def fetch(job_id)
        with_records_lock do
          A3::Domain::AgentJobRecord.from_persisted_form(load_records.fetch(job_id))
        end
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Agent job not found: #{job_id}"
      end

      def all
        with_records_lock do
          load_records.values.map { |record| A3::Domain::AgentJobRecord.from_persisted_form(record) }.sort_by(&:job_id).freeze
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
        temp_path = "#{@path}.tmp"
        File.open(temp_path, "w") do |file|
          file.write(JSON.pretty_generate(records))
          file.flush
          file.fsync
        end
        File.rename(temp_path, @path)
      ensure
        FileUtils.rm_f(temp_path) if defined?(temp_path) && File.exist?(temp_path)
      end
    end
  end
end
