# frozen_string_literal: true

module A3
  module Domain
    module SkillFeedback
      TARGETS = %w[project_skill a2o_preset unknown].freeze
      STATES = %w[new accepted rejected converted_to_ticket applied].freeze
      DEFAULT_STATE = "new"
      PENDING_STATES = %w[new accepted].freeze

      module_function

      def targets
        TARGETS
      end

      def states
        STATES
      end

      def state_for(feedback)
        return DEFAULT_STATE unless feedback.is_a?(Hash)

        state = feedback["state"]
        state.is_a?(String) && !state.empty? ? state : DEFAULT_STATE
      end

      def pending_review?(feedback)
        PENDING_STATES.include?(state_for(feedback))
      end

      def proposal_for(feedback)
        feedback.is_a?(Hash) && feedback["proposal"].is_a?(Hash) ? feedback["proposal"] : {}
      end

      def target_for(feedback)
        proposal_for(feedback)["target"]
      end

      def suggested_patch_for(feedback)
        proposal_for(feedback)["suggested_patch"]
      end

      def group_key_for(feedback)
        [
          target_for(feedback),
          feedback["skill_path"],
          feedback["category"],
          normalize_summary(feedback["summary"])
        ].map { |value| value.to_s }.join("\u001f")
      end

      def normalize_summary(summary)
        summary.to_s.downcase.gsub(/\s+/, " ").strip
      end

      def facet_counts(feedback_entries)
        entries = Array(feedback_entries).select { |feedback| feedback.is_a?(Hash) }
        {
          "target" => count_values(entries.map { |feedback| target_for(feedback) }),
          "category" => count_values(entries.map { |feedback| feedback["category"] }),
          "confidence" => count_values(entries.map { |feedback| feedback["confidence"] }),
          "state" => count_values(entries.map { |feedback| state_for(feedback) })
        }
      end

      def count_values(values)
        values.each_with_object(Hash.new(0)) do |value, counts|
          next if value.to_s.empty?

          counts[value.to_s] += 1
        end.sort.to_h
      end
    end
  end
end
