# frozen_string_literal: true

module A3
  module CLI
    module ShowOutputFormatter
      module TaskFormatter
        module_function

        def lines(task)
          [].tap do |result|
            result << "task #{task.ref} kind=#{task.kind} status=#{task.status} current_run=#{task.current_run_ref}"
            result << "claim_ref=#{task.claim_ref}" if task.claim_ref
            result << "edit_scope=#{task.edit_scope.join(',')}"
            result << "verification_scope=#{task.verification_scope.join(',')}"
            result << "runnable_phase=#{task.runnable_assessment.phase}" if task.runnable_assessment.phase
            result << "runnable_reason=#{task.runnable_assessment.reason}"
            unless task.runnable_assessment.blocking_task_refs.empty?
              result << "runnable_blocked_by=#{task.runnable_assessment.blocking_task_refs.join(',')}"
            end
            if task.topology.parent
              result << "parent=#{task.topology.parent.ref} status=#{task.topology.parent.status} current_run=#{task.topology.parent.current_run_ref}"
            end
            task.topology.children.each do |child|
              result << "child=#{child.ref} status=#{child.status} current_run=#{child.current_run_ref}"
            end
            append_clarification_request_lines(result, task.clarification_request)
            append_skill_feedback_lines(result, task.skill_feedback)
            append_operator_proposal_lines(result, task.operator_proposals)
          end
        end

        def append_clarification_request_lines(result, request)
          return unless request.is_a?(Hash)

          result << "clarification_question=#{request['question']}" if request["question"]
          result << "clarification_context=#{request['context']}" if request["context"]
          options = Array(request["options"]).reject { |option| option.to_s.strip.empty? }
          result << "clarification_options=#{options.join(' | ')}" unless options.empty?
          result << "clarification_recommended_option=#{request['recommended_option']}" if request["recommended_option"]
          result << "clarification_impact=#{request['impact']}" if request["impact"]
        end

        def append_skill_feedback_lines(result, feedback_entries)
          entries = Array(feedback_entries).select { |feedback| feedback.is_a?(Hash) }
          return if entries.empty?

          result << "skill_feedback_count=#{entries.size}"
          A3::Domain::SkillFeedback.facet_counts(entries).each do |facet, counts|
            result << "skill_feedback_#{facet_label(facet)}=#{format_counts(counts)}" unless counts.empty?
          end
          pending_count = entries.count { |feedback| A3::Domain::SkillFeedback.pending_review?(feedback) }
          if pending_count.positive?
            result << "skill_feedback_pending_review=#{pending_count} action=review_or_convert_to_ticket"
          end

          entries.each do |feedback|
            next unless feedback.is_a?(Hash)

            proposal = A3::Domain::SkillFeedback.proposal_for(feedback)
            parts = [
              "category=#{FormattingHelpers.diagnostic_value(feedback['category'])}",
              "target=#{FormattingHelpers.diagnostic_value(proposal['target'])}",
              "state=#{FormattingHelpers.diagnostic_value(A3::Domain::SkillFeedback.state_for(feedback))}"
            ]
            parts << "repo_scope=#{FormattingHelpers.diagnostic_value(feedback['repo_scope'])}" if feedback["repo_scope"]
            parts << "skill_path=#{FormattingHelpers.diagnostic_value(feedback['skill_path'])}" if feedback["skill_path"]
            parts << "confidence=#{FormattingHelpers.diagnostic_value(feedback['confidence'])}" if feedback["confidence"]
            result << "skill_feedback #{parts.join(' ')}"
            result << "skill_feedback_summary=#{feedback['summary']}" if feedback["summary"]
          end
        end

        def append_operator_proposal_lines(result, proposal_entries)
          entries = Array(proposal_entries).select { |proposal| proposal.is_a?(Hash) }
          return if entries.empty?

          result << "operator_proposals_count=#{entries.size}"
          entries.each_with_index do |proposal, index|
            parts = ["index=#{index + 1}"]
            parts << "priority=#{FormattingHelpers.diagnostic_value(proposal['priority'])}" if proposal["priority"]
            parts << "category=#{FormattingHelpers.diagnostic_value(proposal['category'])}" if proposal["category"]
            parts << "evidence_path=#{FormattingHelpers.diagnostic_value(proposal['evidence_path'])}" if proposal["evidence_path"]
            result << "operator_proposal #{parts.join(' ')}"
            result << "operator_proposal_title=#{proposal['title']}" if proposal["title"]
            result << "operator_proposal_summary=#{proposal['summary']}" if proposal["summary"]
            result << "operator_proposal_suggested_action=#{proposal['suggested_action']}" if proposal["suggested_action"]
          end
        end

        def format_counts(counts)
          counts.map { |key, value| "#{key}:#{value}" }.join(",")
        end

        def facet_label(facet)
          return "categories" if facet == "category"

          "#{facet}s"
        end
      end
    end
  end
end
