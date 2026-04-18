# frozen_string_literal: true

require "a3/domain/deep_freezable"

module A3
  module Domain
    class BlockedDiagnosis
      include DeepFreezable

      attr_reader :task_ref, :run_ref, :phase, :outcome, :review_target, :source_descriptor, :scope_snapshot, :artifact_owner,
                  :expected_state, :observed_state, :failing_command, :diagnostic_summary, :infra_diagnostics

      def initialize(task_ref:, run_ref:, phase:, outcome:, review_target:, source_descriptor:, scope_snapshot:, artifact_owner:,
                     expected_state:, observed_state:, failing_command:, diagnostic_summary:, infra_diagnostics:)
        @task_ref = task_ref
        @run_ref = run_ref
        @phase = phase.to_sym
        @outcome = outcome.to_sym
        @review_target = review_target
        @source_descriptor = source_descriptor
        @scope_snapshot = scope_snapshot
        @artifact_owner = artifact_owner
        @expected_state = expected_state
        @observed_state = observed_state
        @failing_command = failing_command
        @diagnostic_summary = diagnostic_summary
        @infra_diagnostics = deep_freeze_value(infra_diagnostics)
        freeze
      end

      def self.from_persisted_form(record)
        return nil unless record

        new(
          task_ref: record.fetch("task_ref"),
          run_ref: record.fetch("run_ref"),
          phase: record.fetch("phase"),
          outcome: record.fetch("outcome"),
          review_target: ReviewTarget.from_persisted_form(record.fetch("review_target")),
          source_descriptor: SourceDescriptor.from_persisted_form(record.fetch("source_descriptor")),
          scope_snapshot: ScopeSnapshot.from_persisted_form(record.fetch("scope_snapshot")),
          artifact_owner: ArtifactOwner.from_persisted_form(record.fetch("artifact_owner")),
          expected_state: record.fetch("expected_state"),
          observed_state: record.fetch("observed_state"),
          failing_command: record.fetch("failing_command"),
          diagnostic_summary: record.fetch("diagnostic_summary"),
          infra_diagnostics: record.fetch("infra_diagnostics")
        )
      end

      def persisted_form
        {
          "task_ref" => task_ref,
          "run_ref" => run_ref,
          "phase" => phase.to_s,
          "outcome" => outcome.to_s,
          "review_target" => review_target.persisted_form,
          "source_descriptor" => source_descriptor.persisted_form,
          "scope_snapshot" => scope_snapshot.persisted_form,
          "artifact_owner" => artifact_owner.persisted_form,
          "expected_state" => expected_state,
          "observed_state" => observed_state,
          "failing_command" => failing_command,
          "diagnostic_summary" => diagnostic_summary,
          "infra_diagnostics" => infra_diagnostics
        }
      end

      def error_category
        text = [phase, diagnostic_summary, observed_state, failing_command, infra_diagnostics.values].join(" ").downcase
        return "configuration_error" if text.match?(/configuration|config|schema|manifest|project\.yaml|executor config|invalid_executor_config|launcher/)
        return "workspace_dirty" if text.match?(/dirty|has changes|changed files do not match|untracked|working tree/)
        return "merge_conflict" if text.match?(/merge conflict|conflict marker|would be overwritten|unmerged/)
        return "verification_failed" if phase == :verification || text.match?(/verification/)
        return "merge_failed" if phase == :merge
        return "executor_failed" if %i[implementation review parent_review worker].include?(phase) || text.match?(/worker|executor/)

        "runtime_failed"
      end

      def remediation_summary
        case error_category
        when "configuration_error"
          "project.yaml と executor 設定を確認し、A2O の公開設定だけを修正してください。内部生成物や launcher.json は編集しません。"
        when "workspace_dirty"
          "表示された repo / file の未コミット変更を commit、stash、または削除してから再実行してください。"
        when "merge_conflict"
          "対象 branch の merge conflict を解消するか、base branch を更新してから再実行してください。"
        when "verification_failed"
          "失敗した verification / remediation command の出力を確認し、product 側のテスト・lint・依存関係を修正してください。"
        when "merge_failed"
          "merge 対象 ref と branch policy を確認し、必要なら手動で branch を整えてから再実行してください。"
        when "executor_failed"
          "executor command が agent 環境で実行可能か、必要な binary と認証、出力 JSON を確認してください。"
        else
          "blocked diagnosis の failing_command、observed_state、evidence を確認して原因を取り除いてください。"
        end
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.task_ref == task_ref &&
          other.run_ref == run_ref &&
          other.phase == phase &&
          other.outcome == outcome &&
          other.review_target == review_target &&
          other.source_descriptor == source_descriptor &&
          other.scope_snapshot == scope_snapshot &&
          other.artifact_owner == artifact_owner &&
          other.expected_state == expected_state &&
          other.observed_state == observed_state &&
          other.failing_command == failing_command &&
          other.diagnostic_summary == diagnostic_summary &&
          other.infra_diagnostics == infra_diagnostics
      end
      alias eql? ==
    end
  end
end
