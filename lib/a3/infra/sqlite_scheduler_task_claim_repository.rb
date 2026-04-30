# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "sqlite3"

module A3
  module Infra
    class SqliteSchedulerTaskClaimRepository
      include A3::Domain::SchedulerTaskClaimRepository

      def initialize(path, claim_ref_generator: -> { SecureRandom.uuid })
        @path = path
        @claim_ref_generator = claim_ref_generator
        ensure_schema!
      end

      def claim_task(task_ref:, phase:, parent_group_key:, claimed_by:, claimed_at:, project_key: A3::Domain::ProjectIdentity.current)
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
        insert_claim(claim)
        claim
      rescue SQLite3::ConstraintException => e
        raise A3::Domain::SchedulerTaskClaimConflict, "scheduler task claim conflict: #{e.message}"
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
        row = db.get_first_row("SELECT payload FROM scheduler_task_claims WHERE claim_ref = ?", [claim_ref])
        raise A3::Domain::RecordNotFound, "Scheduler task claim not found: #{claim_ref}" unless row

        A3::Domain::SchedulerTaskClaimRecord.from_persisted_form(JSON.parse(row.fetch(0)))
      end

      def all
        db.execute("SELECT payload FROM scheduler_task_claims ORDER BY claim_ref ASC").map do |row|
          A3::Domain::SchedulerTaskClaimRecord.from_persisted_form(JSON.parse(row.fetch(0)))
        end.freeze
      end

      def active_claims(project_key: nil)
        normalized_project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        sql = "SELECT payload FROM scheduler_task_claims WHERE state = 'claimed'"
        params = []
        if normalized_project_key
          sql = "#{sql} AND project_key = ?"
          params << normalized_project_key
        end
        sql = "#{sql} ORDER BY claim_ref ASC"
        db.execute(sql, params).map do |row|
          A3::Domain::SchedulerTaskClaimRecord.from_persisted_form(JSON.parse(row.fetch(0)))
        end.freeze
      end

      private

      def insert_claim(claim)
        db.execute(
          "INSERT INTO scheduler_task_claims (claim_ref, project_key, task_ref, parent_group_key, state, payload) VALUES (?, ?, ?, ?, ?, ?)",
          [claim.claim_ref, stored_project_key(claim.project_key), claim.task_ref, claim.parent_group_key, claim.state.to_s, JSON.generate(claim.persisted_form)]
        )
      end

      def update(claim_ref)
        claim = fetch(claim_ref)
        updated = yield claim
        db.execute(
          "UPDATE scheduler_task_claims SET project_key = ?, task_ref = ?, parent_group_key = ?, state = ?, payload = ? WHERE claim_ref = ?",
          [stored_project_key(updated.project_key), updated.task_ref, updated.parent_group_key, updated.state.to_s, JSON.generate(updated.persisted_form), claim_ref]
        )
        updated
      rescue SQLite3::ConstraintException => e
        raise A3::Domain::SchedulerTaskClaimConflict, "scheduler task claim conflict: #{e.message}"
      end

      def ensure_schema!
        FileUtils.mkdir_p(File.dirname(@path))
        db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS scheduler_task_claims (
            claim_ref TEXT PRIMARY KEY,
            project_key TEXT NOT NULL,
            task_ref TEXT NOT NULL,
            parent_group_key TEXT NOT NULL,
            state TEXT NOT NULL,
            payload TEXT NOT NULL
          )
        SQL
        db.execute <<~SQL
          CREATE UNIQUE INDEX IF NOT EXISTS scheduler_task_claims_active_task
          ON scheduler_task_claims(project_key, task_ref)
          WHERE state = 'claimed'
        SQL
        db.execute <<~SQL
          CREATE UNIQUE INDEX IF NOT EXISTS scheduler_task_claims_active_parent_group
          ON scheduler_task_claims(project_key, parent_group_key)
          WHERE state = 'claimed'
        SQL
      end

      def db
        @db ||= SQLite3::Database.new(@path)
      end

      def stored_project_key(project_key)
        project_key || ""
      end
    end
  end
end
