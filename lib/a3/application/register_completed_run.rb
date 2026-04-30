# frozen_string_literal: true

require "a3/domain/branch_namespace"

module A3
  module Application
    class RegisterCompletedRun
      Result = Struct.new(:task, :run, keyword_init: true)

      def initialize(task_repository:, run_repository:, plan_next_phase:, publish_external_task_status: nil, publish_external_task_activity: nil, integration_ref_readiness_checker:, handle_parent_review_disposition: nil, branch_namespace: A3::Domain::BranchNamespace.from_env)
        @task_repository = task_repository
        @run_repository = run_repository
        @plan_next_phase = plan_next_phase
        @publish_external_task_status = publish_external_task_status
        @publish_external_task_activity = publish_external_task_activity
        @branch_namespace = A3::Domain::BranchNamespace.normalize(branch_namespace)
        raise ArgumentError, "integration_ref_readiness_checker is required" unless integration_ref_readiness_checker

        @integration_ref_readiness_checker = integration_ref_readiness_checker
        @handle_parent_review_disposition = handle_parent_review_disposition
      end

      def call(task_ref:, run_ref:, outcome:, execution: nil, phase_runtime: nil)
        task = @task_repository.fetch(task_ref)
        run = @run_repository.fetch(run_ref)
        operator_blocked = external_task_blocked?(task)
        disposition_result = operator_blocked ? nil : resolve_parent_review_disposition(task: task, run: run, execution: execution, outcome: outcome)
        return disposition_result if disposition_result

        artifact_violation = artifact_contract_violation?(task: task, run: run, outcome: outcome)
        terminal_outcome = (artifact_violation || operator_blocked) ? :blocked : outcome
        phase_result = @plan_next_phase.call(task: task, run: run, outcome: terminal_outcome, phase_runtime: phase_runtime)
        completed_run = completed_run_for(task: task, run: run, outcome: terminal_outcome, artifact_violation: artifact_violation)
        completed_task = task.complete_run(
          next_phase: phase_result.next_phase,
          terminal_status: phase_result.terminal_status,
          verification_source_ref: verification_source_ref_for(task: task, outcome: terminal_outcome, execution: execution)
        )

        @run_repository.save(completed_run)
        @task_repository.save(completed_task)
        publish_external_status(task: completed_task, run: completed_run)
        @publish_external_task_activity&.publish(
          task_ref: completed_task.ref,
          external_task_id: completed_task.external_task_id,
          body: completed_run_comment(run: completed_run, task: completed_task, execution: execution),
          **activity_event_kwargs(run: completed_run, task: completed_task)
        )

        Result.new(task: completed_task, run: completed_run)
      end

      private

      def publish_external_status(task:, run:)
        return unless @publish_external_task_status

        kwargs = {
          task_ref: task.ref,
          external_task_id: task.external_task_id,
          status: task.status,
          task_kind: task.kind
        }
        if %i[blocked needs_clarification].include?(task.status.to_sym)
          reason_payload = external_status_reason_payload(run)
          kwargs[:status_reason] = reason_payload.fetch(:reason) if reason_payload.fetch(:reason)
          kwargs[:status_details] = reason_payload.fetch(:details) if reason_payload.fetch(:details)
        end
        @publish_external_task_status.publish(**kwargs)
      end

      def external_task_blocked?(task)
        return false unless @publish_external_task_status&.respond_to?(:blocked?)

        @publish_external_task_status.blocked?(
          task_ref: task.ref,
          external_task_id: task.external_task_id
        )
      end

      def external_status_reason_payload(run)
        phase_record = latest_phase_record(run)
        blocked_diagnosis = phase_record&.blocked_diagnosis
        if blocked_diagnosis
          return {
            reason: single_line(blocked_diagnosis.diagnostic_summary),
            details: compact_hash(
              "run_ref" => run.ref,
              "phase" => run.phase.to_s,
              "error_category" => blocked_diagnosis.error_category.to_s,
              "expected_state" => blocked_diagnosis.expected_state,
              "observed_state" => blocked_diagnosis.observed_state,
              "failing_command" => blocked_diagnosis.failing_command,
              "remediation" => blocked_diagnosis.remediation_summary
            )
          }
        end

        request = phase_record&.execution_record&.clarification_request
        return { reason: nil, details: nil } unless request.is_a?(Hash)

        {
          reason: single_line(request["question"]),
          details: compact_hash(
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "context" => request["context"],
            "options" => request["options"],
            "recommended_option" => request["recommended_option"],
            "impact" => request["impact"]
          )
        }
      end

      def compact_hash(hash)
        hash.each_with_object({}) do |(key, value), memo|
          next if value.nil?
          next if value.respond_to?(:empty?) && value.empty?

          memo[key] = value
        end
      end

      def resolve_parent_review_disposition(task:, run:, execution:, outcome:)
        return nil unless task.kind == :parent
        return nil unless run.phase.to_sym == :review
        return nil if outcome.to_sym == :completed
        return nil if outcome.to_sym == :needs_clarification

        unless @handle_parent_review_disposition
          return finalize_parent_review_disposition(
            task: task,
            run: run,
            result: A3::Application::HandleParentReviewDisposition::Result.new(
              terminal_status: :blocked,
              terminal_outcome: :blocked,
              blocked_diagnosis: A3::Domain::BlockedDiagnosis.new(
                task_ref: task.ref,
                run_ref: run.ref,
                phase: run.phase,
                outcome: :blocked,
                review_target: run.evidence.review_target,
                source_descriptor: run.evidence.source_descriptor,
                scope_snapshot: run.evidence.scope_snapshot,
                artifact_owner: run.evidence.artifact_owner,
                expected_state: "parent review disposition handler is available",
                observed_state: "missing handler",
                failing_command: "parent_review_disposition",
                diagnostic_summary: "parent review disposition handler is missing",
                infra_diagnostics: {}
              )
            )
          )
        end

        disposition_result = @handle_parent_review_disposition.call(
          task: task,
          run: run,
          disposition: execution&.review_disposition
        )
        finalize_parent_review_disposition(task: task, run: run, result: disposition_result)
      end

      def finalize_parent_review_disposition(task:, run:, result:)
        last_phase_record = latest_phase_record(run)
        execution_record = last_phase_record&.execution_record
        completed_run =
          if result.blocked_diagnosis
            run.append_blocked_diagnosis(result.blocked_diagnosis, execution_record: execution_record).complete(outcome: result.terminal_outcome)
          else
            enriched_run = enrich_follow_up_child_evidence(run, child_fingerprints: result.follow_up_child_fingerprints)
            enriched_run.complete(outcome: result.terminal_outcome)
          end
        completed_task = task.complete_run(next_phase: nil, terminal_status: result.terminal_status)

        @run_repository.save(completed_run)
        @task_repository.save(completed_task)
        publish_external_status(task: completed_task, run: completed_run)
        body = completed_run_comment(run: completed_run, task: completed_task, extra_lines: result.comment_lines)
        @publish_external_task_activity&.publish(
          task_ref: completed_task.ref,
          external_task_id: completed_task.external_task_id,
          body: body,
          **activity_event_kwargs(run: completed_run, task: completed_task)
        )
        Result.new(task: completed_task, run: completed_run)
      end

      def activity_event_kwargs(run:, task:)
        event = completed_run_event(run: run, task: task)
        event ? { event: event } : {}
      end

      def completed_run_event(run:, task:)
        case task.status.to_sym
        when :blocked
          blocked_task_event(run: run, task: task)
        when :needs_clarification
          clarification_task_event(run: run, task: task)
        when :done
          completed_task_event(run: run, task: task)
        end
      end

      def blocked_task_event(run:, task:)
        phase_record = latest_phase_record(run)
        blocked_diagnosis = phase_record&.blocked_diagnosis
        summary = single_line(blocked_diagnosis&.diagnostic_summary)
        summary = "Task blocked during #{run.phase}." unless present?(summary)
        {
          "source" => "a2o",
          "kind" => "task_blocked",
          "title" => "A2O task blocked",
          "summary" => summary,
          "severity" => "error",
          "data" => compact_hash(
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "terminal_outcome" => run.terminal_outcome.to_s,
            "task_status" => task.status.to_s,
            "error_category" => blocked_diagnosis&.error_category&.to_s,
            "failing_command" => blocked_diagnosis&.failing_command
          )
        }
      end

      def clarification_task_event(run:, task:)
        request = latest_phase_record(run)&.execution_record&.clarification_request
        summary = request.is_a?(Hash) ? single_line(request["question"]) : nil
        summary = "Clarification requested during #{run.phase}." unless present?(summary)
        {
          "source" => "a2o",
          "kind" => "clarification_requested",
          "title" => "Clarification requested",
          "summary" => summary,
          "severity" => "warning",
          "data" => compact_hash(
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "terminal_outcome" => run.terminal_outcome.to_s,
            "task_status" => task.status.to_s,
            "question" => request.is_a?(Hash) ? request["question"] : nil,
            "context" => request.is_a?(Hash) ? request["context"] : nil,
            "options" => request.is_a?(Hash) ? request["options"] : nil
          )
        }
      end

      def completed_task_event(run:, task:)
        {
          "source" => "a2o",
          "kind" => "task_completed",
          "title" => "A2O task completed",
          "summary" => "Completed #{run.phase} run #{run.ref}.",
          "severity" => "success",
          "data" => compact_hash(
            "run_ref" => run.ref,
            "phase" => run.phase.to_s,
            "terminal_outcome" => run.terminal_outcome.to_s,
            "task_status" => task.status.to_s
          )
        }
      end

      def enrich_follow_up_child_evidence(run, child_fingerprints:)
        last_phase_record = run.phase_records.last
        execution_record = last_phase_record&.execution_record
        return run if execution_record.nil?

        updated_execution_record = execution_record.with_follow_up_child_fingerprints(Array(child_fingerprints))
        run.replace_latest_phase_record(last_phase_record.with_execution_record(updated_execution_record))
      end

      def verification_source_ref_for(task:, outcome:, execution:)
        outcome_name = outcome.to_sym
        return execution&.merge_recovery_verification_source_ref if outcome_name == :verification_required
        return task.verification_source_ref if %i[retryable terminal_noop].include?(outcome_name)

        nil
      end

      def completed_run_for(task:, run:, outcome:, artifact_violation:)
        return run.complete(outcome: outcome) unless artifact_violation

        run.append_blocked_diagnosis(
          artifact_contract_blocked_diagnosis(task: task, run: run)
        ).complete(outcome: :blocked)
      end

      def artifact_contract_violation?(task:, run:, outcome:)
        return false unless outcome.to_sym == :completed
        return false unless task.kind == :child
        return false unless run.phase.to_sym == :merge
        return false unless task.parent_ref

        !@integration_ref_readiness_checker.check(
          ref: parent_integration_ref_for(task),
          repo_slots: task.edit_scope
        ).ready?
      end

      def artifact_contract_blocked_diagnosis(task:, run:)
        readiness = @integration_ref_readiness_checker.check(
          ref: parent_integration_ref_for(task),
          repo_slots: task.edit_scope
        )
        A3::Domain::BlockedDiagnosis.new(
          task_ref: task.ref,
          run_ref: run.ref,
          phase: run.phase,
          outcome: :blocked,
          review_target: run.evidence.review_target,
          source_descriptor: run.source_descriptor,
          scope_snapshot: run.scope_snapshot,
          artifact_owner: run.artifact_owner,
          expected_state: "parent integration ref is available across all edit scope slots",
          observed_state: readiness.diagnostic_summary,
          failing_command: "integration_ref_readiness_check",
          diagnostic_summary: readiness.diagnostic_summary,
          infra_diagnostics: { "missing_slots" => readiness.missing_slots.map(&:to_s), "ref" => readiness.ref }
        )
      end

      def parent_integration_ref_for(task)
        parts = ["refs/heads/a2o"]
        parts << @branch_namespace if @branch_namespace
        parts << "parent"
        parts << task.parent_ref.tr("#", "-")
        parts.join("/")
      end

      def completed_run_comment(run:, task:, execution: nil, extra_lines: nil)
        lines = [
          "A2O 実行完了: #{run.phase}",
          "run_ref: #{run.ref}",
          "結果: #{run.terminal_outcome}",
          "タスク状態: #{task.status}"
        ]

        phase_record = latest_phase_record(run)
        execution_record = phase_record&.execution_record
        blocked_diagnosis = phase_record&.blocked_diagnosis

        if execution_record&.summary && !execution_record.summary.empty?
          lines << "要約: #{single_line(execution_record.summary)}"
        end

        append_review_disposition_comment_lines(lines, execution_record&.review_disposition)
        append_docs_impact_comment_lines(lines, execution_record&.docs_impact)
        append_clarification_request_comment_lines(lines, execution_record&.clarification_request)
        append_merge_recovery_comment_lines(lines, execution_record&.diagnostics || execution&.diagnostics)
        append_worker_result_diagnostic_comment_lines(
          lines,
          execution_record&.diagnostics || execution&.diagnostics || blocked_diagnosis&.infra_diagnostics,
          worker_result_context: worker_result_diagnostic_context?(execution_record: execution_record, execution: execution, blocked_diagnosis: blocked_diagnosis)
        )

        if blocked_diagnosis
          lines << "エラー分類: #{single_line(blocked_diagnosis.error_category)}"
          lines << "主要失敗要約: #{single_line(blocked_diagnosis.diagnostic_summary)}"
          lines << "主要失敗コマンド: #{single_line(blocked_diagnosis.failing_command)}" if present?(blocked_diagnosis.failing_command)
          append_inherited_parent_comment_lines(lines, execution_record&.diagnostics || blocked_diagnosis.infra_diagnostics)
          lines << "次の対応: #{single_line(blocked_diagnosis.remediation_summary)}"
          lines << "観測状態: #{single_line(blocked_diagnosis.observed_state)}" if present?(blocked_diagnosis.observed_state)
        elsif execution_record&.failing_command
          lines << "失敗コマンド: #{single_line(execution_record.failing_command)}"
          append_inherited_parent_comment_lines(lines, execution_record.diagnostics)
          lines << "観測状態: #{single_line(execution_record.observed_state)}" if present?(execution_record.observed_state)
        end
        Array(extra_lines).each { |line| lines << line }

        lines.join("\n")
      end

      def append_review_disposition_comment_lines(lines, disposition)
        return unless disposition.is_a?(Hash)

        fields = []
        fields << disposition["kind"] if present?(disposition["kind"])
        slot_scopes = Array(disposition["slot_scopes"]).map { |scope| single_line(scope) }.reject(&:empty?)
        fields << "slot_scopes=#{slot_scopes.join(',')}" unless slot_scopes.empty?
        fields << "finding_key=#{single_line(disposition['finding_key'])}" if present?(disposition["finding_key"])
        lines << "レビュー結果: #{fields.join(' ')}" unless fields.empty?
        lines << "レビュー要約: #{single_line(disposition['summary'])}" if present?(disposition["summary"])
        lines << "レビュー詳細: #{single_line(disposition['description'])}" if present?(disposition["description"])
      end

      def append_clarification_request_comment_lines(lines, request)
        return unless request.is_a?(Hash)

        lines << "確認依頼: #{single_line(request['question'])}" if present?(request["question"])
        lines << "確認背景: #{single_line(request['context'])}" if present?(request["context"])
        options = Array(request["options"]).map { |option| single_line(option) }.reject(&:empty?)
        lines << "選択肢: #{options.each_with_index.map { |option, index| "#{index + 1}. #{option}" }.join(' / ')}" unless options.empty?
        lines << "推奨: #{single_line(request['recommended_option'])}" if present?(request["recommended_option"])
        lines << "影響: #{single_line(request['impact'])}" if present?(request["impact"])
      end

      def append_docs_impact_comment_lines(lines, docs_impact)
        return unless docs_impact.is_a?(Hash)

        disposition = docs_impact["disposition"]
        categories = summary_list(docs_impact["categories"])
        summary = []
        summary << single_line(disposition) if present?(disposition)
        summary << "categories=#{categories}" if present?(categories)
        summary << "review=#{single_line(docs_impact['review_disposition'])}" if present?(docs_impact["review_disposition"])
        lines << "docs-impact: #{summary.join(' ')}" unless summary.empty?

        updated_docs = summary_list(docs_impact["updated_docs"])
        skipped_docs = skipped_docs_summary(docs_impact["skipped_docs"])
        authorities = summary_list(docs_impact["updated_authorities"])
        matched_rules = summary_list(docs_impact["matched_rules"])
        traceability = traceability_summary(docs_impact["traceability"])

        lines << "docs-updated: #{updated_docs}" if present?(updated_docs)
        lines << "docs-skipped: #{skipped_docs}" if present?(skipped_docs)
        lines << "docs-authorities: #{authorities}" if present?(authorities)
        lines << "docs-rules: #{matched_rules}" if present?(matched_rules)
        lines << "docs-traceability: #{traceability}" if present?(traceability)
      end

      def summary_list(value, limit: 5)
        entries = Array(value).map { |entry| single_line(entry) }.reject(&:empty?)
        return nil if entries.empty?

        suffix = entries.length > limit ? ",+#{entries.length - limit}" : ""
        truncate_comment_value("#{entries.first(limit).join(',')}#{suffix}")
      end

      def skipped_docs_summary(value, limit: 3)
        entries = Array(value).filter_map do |entry|
          next unless entry.is_a?(Hash)

          path = single_line(entry["path"])
          reason = single_line(entry["reason"])
          next if path.empty?

          reason.empty? ? path : "#{path}(#{reason})"
        end
        return nil if entries.empty?

        suffix = entries.length > limit ? ",+#{entries.length - limit}" : ""
        truncate_comment_value("#{entries.first(limit).join(',')}#{suffix}")
      end

      def traceability_summary(value)
        return nil unless value.is_a?(Hash)

        fields = []
        {
          "requirements" => "related_requirements",
          "issues" => "source_issues",
          "tickets" => "related_tickets"
        }.each do |label, key|
          entries = summary_list(value[key], limit: 4)
          fields << "#{label}=#{entries}" if present?(entries)
        end
        fields.empty? ? nil : truncate_comment_value(fields.join(" "))
      end

      def append_worker_result_diagnostic_comment_lines(lines, diagnostics, worker_result_context:)
        return unless diagnostics.is_a?(Hash)
        return unless worker_result_context || diagnostics.key?("worker_response_bundle")

        Array(diagnostics["validation_errors"]).first(5).each do |error|
          next unless present?(error)

          lines << "worker_result_validation_error: #{single_line(error)}"
        end

        bundle = diagnostics["worker_response_bundle"]
        lines << "worker_response: #{worker_response_summary(bundle)}" if bundle
      end

      def worker_result_diagnostic_context?(execution_record:, execution:, blocked_diagnosis:)
        failing_command = execution_record&.failing_command || execution&.failing_command || blocked_diagnosis&.failing_command
        observed_state = execution_record&.observed_state || execution&.observed_state || blocked_diagnosis&.observed_state
        %w[worker_result_schema worker_result_json].include?(failing_command.to_s) ||
          observed_state.to_s == "invalid_worker_result"
      end

      def worker_response_summary(bundle)
        return truncate_comment_value(single_line(bundle.inspect)) unless bundle.is_a?(Hash)

        fields = []
        %w[success task_ref run_ref phase summary failing_command observed_state rework_required].each do |key|
          fields << "#{key}=#{single_line(bundle[key])}" if bundle.key?(key)
        end
        disposition = bundle["review_disposition"]
        if disposition.is_a?(Hash)
          review_fields = %w[kind finding_key].filter_map do |key|
            "#{key}=#{single_line(disposition[key])}" if present?(disposition[key])
          end
          slot_scopes = Array(disposition["slot_scopes"]).map { |scope| single_line(scope) }.reject(&:empty?)
          review_fields.insert(1, "slot_scopes=#{slot_scopes.join(',')}") unless slot_scopes.empty?
          fields << "review_disposition=#{review_fields.join(' ')}" unless review_fields.empty?
        end
        truncate_comment_value(fields.reject(&:empty?).join(" "))
      end

      def truncate_comment_value(value, limit = 600)
        text = value.to_s
        return text if text.length <= limit

        "#{text[0, limit]}..."
      end

      def append_merge_recovery_comment_lines(lines, diagnostics)
        return unless diagnostics.is_a?(Hash)

        recovery = diagnostics["merge_recovery"]
        return unless recovery.is_a?(Hash)

        lines << "merge_recovery: #{single_line(recovery['status'])}" if present?(recovery["status"])
        if present?(recovery["target_ref"])
          lines << "merge_recovery_target: #{single_line(recovery['target_ref'])}"
        end
        if present?(recovery["publish_before_head"]) || present?(recovery["publish_after_head"])
          lines << "merge_recovery_publish: #{single_line(recovery['publish_before_head'])}..#{single_line(recovery['publish_after_head'])}"
        end
      end

      def append_inherited_parent_comment_lines(lines, diagnostics)
        return unless diagnostics.is_a?(Hash)

        inherited_ref = diagnostics["inherited_parent_ref"]
        inherited_fingerprint = diagnostics["inherited_parent_state_fingerprint"]
        return unless present?(inherited_ref) || present?(inherited_fingerprint)

        lines << "継承元親状態: #{single_line(inherited_ref)}" if present?(inherited_ref)
        lines << "継承元親状態 fingerprint: #{single_line(inherited_fingerprint)}" if present?(inherited_fingerprint)
      end

      def latest_phase_record(run)
        run.phase_records.reverse_each.find { |record| record.phase == run.phase }
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def single_line(text)
        text.to_s.split("\n").map(&:strip).reject(&:empty?).join(" ")
      end

    end
  end
end
