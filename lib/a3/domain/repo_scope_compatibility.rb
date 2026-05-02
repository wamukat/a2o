# frozen_string_literal: true

module A3
  module Domain
    module RepoScopeCompatibility
      LEGACY_MULTI_REPO_SCOPE = "both"
      LEGACY_REPO_SCOPE_FIELD = "repo_scope"
      CANONICAL_REVIEW_DISPOSITION_SCOPE_FIELD = "slot_scopes"
      REMOVED_REVIEW_DISPOSITION_REPO_SCOPE_ERROR =
        "review_disposition.repo_scope is not supported; use review_disposition.slot_scopes"

      module_function

      def prompt_slots(repo_scope:, repo_slots:, fallback_slots:)
        slots = Array(repo_slots).map(&:to_s).reject(&:empty?)
        return slots unless slots.empty?

        scope = repo_scope.to_s
        return [] if scope.empty?
        return [scope] unless scope == LEGACY_MULTI_REPO_SCOPE

        Array(fallback_slots).map(&:to_s).reject(&:empty?).uniq
      end
    end
  end
end
