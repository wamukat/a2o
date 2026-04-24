# frozen_string_literal: true

module A3
  module Application
    class GenerateSkillFeedbackProposal
      def initialize(list_skill_feedback:)
        @list_skill_feedback = list_skill_feedback
      end

      def call(state: "new", target: nil, format: :ticket)
        entries = @list_skill_feedback.call(state: state, target: target)
        return "skill_feedback_proposal=none\n" if entries.empty?

        case format.to_sym
        when :ticket
          ticket_body(entries)
        when :patch
          patch_body(entries)
        else
          raise ArgumentError, "unsupported skill feedback proposal format: #{format}"
        end
      end

      private

      def ticket_body(entries)
        lines = [
          "# Skill feedback adoption proposal",
          "",
          "This proposal was generated from collected A2O skill feedback. It is a review draft only; it does not modify skill files automatically.",
          "",
          "## Feedback groups",
          ""
        ]
        grouped(entries).each do |group|
          entry = group.first
          lines << "- #{entry.summary}"
          lines << "  - count: #{group.size}"
          lines << "  - target: #{entry.target || 'unknown'}"
          lines << "  - skill_path: #{entry.skill_path}" if entry.skill_path
          lines << "  - category: #{entry.category}" if entry.category
          lines << "  - confidence: #{entry.confidence}" if entry.confidence
          lines << "  - source: #{group.map { |item| "#{item.task_ref}/#{item.run_ref}/#{item.phase}" }.uniq.join(', ')}"
          lines << "  - suggested_patch: #{entry.suggested_patch}" if entry.suggested_patch
        end
        lines << ""
        lines << "## Acceptance criteria"
        lines << ""
        lines << "- [ ] Review whether the feedback should update a project skill, an A2O preset, or be rejected."
        lines << "- [ ] Apply any accepted change through a reviewed patch."
        lines << "- [ ] Record the final feedback lifecycle state."
        lines.join("\n") + "\n"
      end

      def patch_body(entries)
        lines = [
          "# Draft skill patch",
          "",
          "Review this draft before applying it. A2O does not apply skill feedback automatically.",
          ""
        ]
        grouped(entries).each do |group|
          entry = group.first
          next if entry.suggested_patch.to_s.empty?

          lines << "## #{entry.skill_path || entry.target || 'unknown target'}"
          lines << ""
          lines << "Source feedback: #{entry.summary}"
          lines << ""
          lines << "```text"
          lines << entry.suggested_patch
          lines << "```"
          lines << ""
        end
        lines << "No suggested_patch values were present in the selected feedback." if lines.size == 4
        lines.join("\n")
      end

      def grouped(entries)
        entries.group_by(&:group_key).values
      end
    end
  end
end
