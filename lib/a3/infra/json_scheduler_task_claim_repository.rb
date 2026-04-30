# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module A3
  module Infra
    class JsonSchedulerTaskClaimRepository
      include A3::Domain::SchedulerTaskClaimRepository

      def initialize(path, claim_ref_generator: -> { SecureRandom.uuid })
        @path = path
        @claim_ref_generator = claim_ref_generator
      end

      def claim_task(task_ref:, phase:, parent_group_key:, claimed_by:, claimed_at:, project_key: A3::Domain::ProjectIdentity.current)
        with_records_lock do
          records = load_records
          project_key = A3::Domain::ProjectIdentity.normalize(project_key)
          assert_no_active_conflict!(records, project_key: project_key, task_ref: task_ref, parent_group_key: parent_group_key)
          claim = A3::Domain::SchedulerTaskClaimRecord.new(
            claim_ref: @claim_ref_generator.call,
            project_key: project_key,
            task_ref: task_ref,
            phase: phase,
            parent_group_key: parent_group_key,
            state: :claimed,
            claimed_by: claimed_by,
            claimed_at: claimed_at
          )
          records[claim.claim_ref] = claim.persisted_form
          write_records(records)
          claim
        end
      end

      def link_run(claim_ref:, run_ref:)
        update(claim_ref) { |claim| claim.link_run(run_ref: run_ref) }
      end

      def release_claim(claim_ref:, run_ref: nil)
        update(claim_ref) { |claim| claim.release(run_ref: run_ref) }
      end

      def heartbeat(claim_ref:, heartbeat_at:)
        update(claim_ref) { |claim| claim.heartbeat(heartbeat_at: heartbeat_at) }
      end

      def mark_claim_stale(claim_ref:, reason:)
        update(claim_ref) { |claim| claim.mark_stale(reason: reason) }
      end

      def fetch(claim_ref)
        with_records_lock do
          A3::Domain::SchedulerTaskClaimRecord.from_persisted_form(load_records.fetch(claim_ref))
        end
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Scheduler task claim not found: #{claim_ref}"
      end

      def all
        with_records_lock do
          load_records.values.map { |record| A3::Domain::SchedulerTaskClaimRecord.from_persisted_form(record) }.sort_by(&:claim_ref).freeze
        end
      end

      def active_claims(project_key: nil)
        normalized_project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        all.select do |claim|
          claim.active? && (normalized_project_key.nil? || claim.project_key == normalized_project_key)
        end.freeze
      end

      private

      def update(claim_ref)
        with_records_lock do
          records = load_records
          claim = A3::Domain::SchedulerTaskClaimRecord.from_persisted_form(records.fetch(claim_ref))
          updated = yield claim
          records[claim_ref] = updated.persisted_form
          write_records(records)
          updated
        end
      rescue KeyError
        raise A3::Domain::RecordNotFound, "Scheduler task claim not found: #{claim_ref}"
      end

      def assert_no_active_conflict!(records, project_key:, task_ref:, parent_group_key:)
        records.each_value do |payload|
          claim = A3::Domain::SchedulerTaskClaimRecord.from_persisted_form(payload)
          next unless claim.active? && claim.project_key == project_key

          if claim.task_ref == task_ref.to_s
            raise A3::Domain::SchedulerTaskClaimConflict, "scheduler task claim conflict: active task #{task_ref}"
          end
          if claim.parent_group_key == parent_group_key.to_s
            raise A3::Domain::SchedulerTaskClaimConflict, "scheduler task claim conflict: active parent group #{parent_group_key}"
          end
        end
      end

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
