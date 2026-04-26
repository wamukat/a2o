# frozen_string_literal: true

require "json"

module A3
  module Application
    class ShowDecompositionStatus
      Status = Struct.new(:task_ref, :state, :proposal_fingerprint, :disposition, :blocked_reason, :evidence_paths, keyword_init: true)

      def initialize(storage_dir:)
        @storage_dir = storage_dir
      end

      def call(task_ref:)
        root = File.join(@storage_dir, "decomposition-evidence", slugify(task_ref))
        investigation_path = File.join(root, "investigation.json")
        proposal_path = File.join(root, "proposal.json")
        review_path = File.join(root, "proposal-review.json")
        proposal = load_json(proposal_path)
        review = load_json(review_path)
        disposition = review && review["disposition"]
        state =
          if review && disposition == "blocked"
            "blocked"
          elsif review && disposition == "eligible"
            "done"
          elsif proposal
            "active"
          elsif File.exist?(investigation_path)
            "active"
          else
            "none"
          end

        Status.new(
          task_ref: task_ref,
          state: state,
          proposal_fingerprint: proposal && proposal["proposal_fingerprint"],
          disposition: disposition,
          blocked_reason: review && review["summary"],
          evidence_paths: {
            "investigation" => investigation_path,
            "proposal" => proposal_path,
            "proposal_review" => review_path
          }.select { |_key, path| File.exist?(path) }
        )
      end

      private

      def load_json(path)
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def slugify(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
      end
    end
  end
end
