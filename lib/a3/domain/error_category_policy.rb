# frozen_string_literal: true

module A3
  module Domain
    module ErrorCategoryPolicy
      module_function

      CONFIGURATION_PATTERN = /configuration|config|schema|manifest|project\.yaml|executor config|invalid_executor_config|launcher/
      STRICT_WORKSPACE_DIRTY_PATTERN = /slot .* has changes|changed files do not match|changed files|working tree is dirty/
      LOOSE_WORKSPACE_DIRTY_PATTERN = /dirty|has changes|changed files do not match|changed files|untracked|working tree/
      MERGE_CONFLICT_PATTERN = /merge conflict|conflict marker|would be overwritten|unmerged/
      EXECUTOR_PATTERN = /worker|executor/
      BLOCKED_EXECUTOR_PHASES = %i[implementation review parent_review worker].freeze
      BLOCKED_REMEDIATIONS = {
        "configuration_error" => "project.yaml と executor 設定を確認し、A2O の公開設定だけを修正してください。内部生成物や launcher.json は編集しません。",
        "workspace_dirty" => "表示された repo / file の未コミット変更を commit、stash、または削除してから再実行してください。",
        "merge_conflict" => "対象 branch の merge conflict を解消するか、base branch を更新してから再実行してください。",
        "verification_failed" => "失敗した verification / remediation command の出力を確認し、product 側のテスト・lint・依存関係を修正してください。",
        "merge_failed" => "merge 対象 ref と branch policy を確認し、必要なら手動で branch を整えてから再実行してください。",
        "executor_failed" => "executor command が agent 環境で実行可能か、必要な binary と認証、出力 JSON を確認してください。"
      }.freeze
      WORKER_REMEDIATIONS = {
        "configuration_error" => "Review project.yaml and executor settings. Do not edit generated launcher.json files.",
        "workspace_dirty" => "Clean, commit, or stash the reported repo files before rerunning A2O.",
        "merge_conflict" => "Resolve the merge conflict or update the base branch before rerunning A2O.",
        "verification_failed" => "Inspect the verification command output and fix product tests, lint, or dependencies.",
        "merge_failed" => "Check the merge target ref and branch policy before rerunning A2O.",
        "executor_failed" => "Check that the executor binary, credentials, and worker result JSON are valid."
      }.freeze

      def blocked_error_category(phase:, diagnostic_summary:, observed_state:, failing_command:, infra_diagnostics:)
        text = normalized_text(phase, diagnostic_summary, observed_state, failing_command, infra_diagnostics.to_h.values)
        return "configuration_error" if text.match?(CONFIGURATION_PATTERN)
        return "workspace_dirty" if failing_command.to_s == "publish_workspace_changes" || text.match?(STRICT_WORKSPACE_DIRTY_PATTERN)
        return "verification_failed" if phase.to_sym == :verification || text.match?(/verification/)
        return "workspace_dirty" if text.match?(LOOSE_WORKSPACE_DIRTY_PATTERN)
        return "merge_conflict" if text.match?(MERGE_CONFLICT_PATTERN)
        return "merge_failed" if phase.to_sym == :merge
        return "executor_failed" if BLOCKED_EXECUTOR_PHASES.include?(phase.to_sym) || text.match?(EXECUTOR_PATTERN)

        "runtime_failed"
      end

      def blocked_remediation(category)
        BLOCKED_REMEDIATIONS.fetch(category, "blocked diagnosis の failing_command、observed_state、evidence を確認して原因を取り除いてください。")
      end

      def worker_error_category(summary:, observed_state:, phase:)
        text = normalized_text(summary, observed_state, phase)
        return "configuration_error" if text.match?(/config|schema|project\.yaml|executor config|invalid_executor_config|launcher/)
        return "workspace_dirty" if text.match?(STRICT_WORKSPACE_DIRTY_PATTERN)
        return "verification_failed" if phase.to_s == "verification"
        return "workspace_dirty" if text.match?(/dirty|has changes|untracked|working tree/)
        return "merge_conflict" if text.match?(/merge conflict|conflict marker|unmerged/)
        return "merge_failed" if phase.to_s == "merge"

        "executor_failed"
      end

      def worker_remediation(category)
        WORKER_REMEDIATIONS.fetch(category, "Inspect failing_command, observed_state, and evidence, then remove the blocking cause.")
      end

      def normalized_text(*parts)
        parts.flatten.compact.join(" ").downcase
      end
      private_class_method :normalized_text
    end
  end
end
