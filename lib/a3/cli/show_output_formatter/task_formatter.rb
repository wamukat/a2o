# frozen_string_literal: true

module A3
  module CLI
    module ShowOutputFormatter
      module TaskFormatter
        module_function

        def lines(task)
          [].tap do |result|
            result << "task #{task.ref} kind=#{task.kind} status=#{task.status} current_run=#{task.current_run_ref}"
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
            append_skill_feedback_lines(result, task.skill_feedback)
          end
        end

        def append_skill_feedback_lines(result, feedback_entries)
          Array(feedback_entries).each do |feedback|
            next unless feedback.is_a?(Hash)

            proposal = feedback["proposal"].is_a?(Hash) ? feedback["proposal"] : {}
            parts = [
              "category=#{FormattingHelpers.diagnostic_value(feedback['category'])}",
              "target=#{FormattingHelpers.diagnostic_value(proposal['target'])}"
            ]
            parts << "repo_scope=#{FormattingHelpers.diagnostic_value(feedback['repo_scope'])}" if feedback["repo_scope"]
            parts << "skill_path=#{FormattingHelpers.diagnostic_value(feedback['skill_path'])}" if feedback["skill_path"]
            parts << "confidence=#{FormattingHelpers.diagnostic_value(feedback['confidence'])}" if feedback["confidence"]
            result << "skill_feedback #{parts.join(' ')}"
            result << "skill_feedback_summary=#{feedback['summary']}" if feedback["summary"]
          end
        end
      end
    end
  end
end
