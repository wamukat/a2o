# frozen_string_literal: true

require "fileutils"
require "json"
require "a3/domain/refactoring_assessment"
require "a3/domain/source_remote"

module A3
  module Application
    class RunDecompositionChildCreation
      Result = Struct.new(:success, :status, :summary, :parent_ref, :child_refs, :child_keys, :evidence_path, :source_ticket_summary, :source_ticket_summary_published, keyword_init: true)

      def initialize(storage_dir:, child_writer:, publish_external_task_activity: nil, system_comment_locale: "en")
        @storage_dir = storage_dir
        @child_writer = child_writer
        @publish_external_task_activity = publish_external_task_activity
        @system_comment_locale = normalize_system_comment_locale(system_comment_locale)
      end

      def call(task:, gate:, proposal_evidence_path: nil, review_evidence_path: nil, source_remote: nil)
        source_remote = A3::Domain::SourceRemote.normalize(source_remote)
        proposal_evidence_path ||= evidence_path_for(task.ref, "proposal.json")
        review_evidence_path ||= evidence_path_for(task.ref, "proposal-review.json")
        proposal_evidence = load_json(proposal_evidence_path)
        review_evidence = load_json(review_evidence_path)
        return gate_closed_result(task: task, proposal_evidence: proposal_evidence, review_evidence: review_evidence, source_remote: source_remote) unless gate

        validation_errors = validation_errors_for(proposal_evidence: proposal_evidence, review_evidence: review_evidence)
        return blocked_result(task: task, summary: validation_errors.join("; "), proposal_evidence: proposal_evidence, review_evidence: review_evidence, source_remote: source_remote) unless validation_errors.empty?

        outcome = proposal_outcome(proposal_evidence.fetch("proposal"))
        return outcome_result(task: task, outcome: outcome, proposal_evidence: proposal_evidence, review_evidence: review_evidence, source_remote: source_remote) unless outcome == "draft_children"

        write_result = @child_writer.call(
          parent_task_ref: task.ref,
          parent_external_task_id: task.external_task_id,
          proposal_evidence: proposal_evidence,
          source_remote: source_remote
        )
        if write_result.success?
          persist_evidence(
            task: task,
            success: true,
            status: "created",
            summary: "created or reconciled #{write_result.child_refs.size} decomposition child ticket(s)",
            proposal_evidence: proposal_evidence,
            review_evidence: review_evidence,
            writer_result: writer_result_payload(write_result),
            source_remote: source_remote
          )
        else
          blocked_result(
            task: task,
            summary: write_result.summary || "decomposition child creation failed",
            proposal_evidence: proposal_evidence,
            review_evidence: review_evidence,
            writer_result: writer_result_payload(write_result),
            source_remote: source_remote
          )
        end
      end

      private

      def validation_errors_for(proposal_evidence:, review_evidence:)
        errors = []
        errors << "proposal evidence did not succeed" unless proposal_evidence.is_a?(Hash) && proposal_evidence["success"] == true
        proposal = proposal_evidence.is_a?(Hash) ? proposal_evidence["proposal"] : nil
        unless proposal.is_a?(Hash)
          errors << "proposal is missing"
        else
          outcome = proposal_outcome(proposal)
          errors << "proposal outcome is unsupported: #{outcome}" unless %w[draft_children no_action needs_clarification].include?(outcome)
          children = proposal["children"]
          errors << "proposal children must be an array" unless children.is_a?(Array)
          if outcome == "draft_children"
            errors << "proposal children are missing" unless children.is_a?(Array) && children.any?
          elsif children.is_a?(Array) && children.any?
            errors << "proposal children must be empty for #{outcome} outcome"
          end
          errors << "proposal reason is missing for #{outcome} outcome" if %w[no_action needs_clarification].include?(outcome) && blank?(proposal["reason"])
          errors << "proposal questions are missing for needs_clarification outcome" if outcome == "needs_clarification" && !non_empty_array?(proposal["questions"])
          if proposal.key?("refactoring_assessment")
            errors.concat(A3::Domain::RefactoringAssessment.validation_errors(proposal["refactoring_assessment"]))
          end
        end
        errors << "proposal review is not eligible" unless review_evidence.is_a?(Hash) && review_evidence["disposition"] == "eligible"
        if proposal_evidence.is_a?(Hash) && review_evidence.is_a?(Hash)
          proposal_fingerprint = proposal_evidence["proposal_fingerprint"]
          reviewed_fingerprint = review_evidence.dig("request", "proposal_evidence", "proposal_fingerprint") || review_evidence["proposal_fingerprint"]
          errors << "proposal review fingerprint does not match proposal" unless reviewed_fingerprint == proposal_fingerprint
        end
        errors
      end

      def blocked_result(task:, summary:, proposal_evidence: nil, review_evidence: nil, writer_result: nil, source_remote: nil)
        persist_evidence(
          task: task,
          success: false,
          status: "blocked",
          summary: summary,
          proposal_evidence: proposal_evidence,
          review_evidence: review_evidence,
          writer_result: writer_result,
          source_remote: source_remote
        )
      end

      def gate_closed_result(task:, proposal_evidence:, review_evidence:, source_remote:)
        persist_evidence(
          task: task,
          success: nil,
          status: "gate_closed",
          summary: "decomposition child creation gate is closed",
          proposal_evidence: proposal_evidence,
          review_evidence: review_evidence,
          writer_result: nil,
          source_remote: source_remote
        )
      end

      def outcome_result(task:, outcome:, proposal_evidence:, review_evidence:, source_remote:)
        proposal = proposal_evidence.fetch("proposal")
        summary =
          case outcome
          when "no_action"
            "decomposition completed with no implementation needed: #{proposal.fetch('reason')}"
          when "needs_clarification"
            "decomposition needs clarification: #{proposal.fetch('reason')}"
          else
            "decomposition completed with outcome #{outcome}"
          end
        persist_evidence(
          task: task,
          success: true,
          status: outcome,
          summary: summary,
          proposal_evidence: proposal_evidence,
          review_evidence: review_evidence,
          writer_result: nil,
          source_remote: source_remote
        )
      end

      def persist_evidence(task:, success:, status:, summary:, proposal_evidence:, review_evidence:, writer_result:, source_remote:)
        evidence_dir = File.join(@storage_dir, "decomposition-evidence", slugify(task.ref))
        FileUtils.mkdir_p(evidence_dir)
        path = File.join(evidence_dir, "child-creation.json")
        child_refs = writer_result ? Array(writer_result["child_refs"]) : []
        child_keys = writer_result ? Array(writer_result["child_keys"]) : []
        parent_ref = writer_result && writer_result["parent_ref"]
        source_ticket_summary = source_ticket_summary_for(
          success: success,
          status: status,
          summary: summary,
          parent_ref: parent_ref,
          child_refs: child_refs,
          proposal: proposal_evidence && proposal_evidence["proposal"],
          evidence_path: path
        )
        evidence_payload = {
          "task_ref" => task.ref,
          "phase" => "child_creation",
          "success" => success,
          "status" => status,
          "summary" => summary,
          "proposal_fingerprint" => proposal_evidence && proposal_evidence["proposal_fingerprint"],
          "review_disposition" => review_evidence && review_evidence["disposition"],
          "proposal_outcome" => proposal_evidence && proposal_evidence["proposal"] && proposal_outcome(proposal_evidence["proposal"]),
          "generated_parent_ref" => parent_ref,
          "child_refs" => child_refs,
          "child_keys" => child_keys,
          "child_refs_by_key" => child_refs_by_key(child_keys: child_keys, child_refs: child_refs),
          "source_ticket_summary" => source_ticket_summary,
          "proposal_evidence" => proposal_evidence,
          "review_evidence" => review_evidence,
          "writer_result" => writer_result
        }
        evidence_payload["source_remote"] = source_remote if source_remote
        File.write(
          path,
          "#{JSON.pretty_generate(evidence_payload)}\n"
        )
        summary_published = publish_source_ticket_summary(task: task, body: source_ticket_summary)
        Result.new(
          success: success,
          status: status,
          summary: summary,
          parent_ref: parent_ref,
          child_refs: child_refs,
          child_keys: child_keys,
          evidence_path: path,
          source_ticket_summary: source_ticket_summary,
          source_ticket_summary_published: summary_published
        )
      end

      def child_refs_by_key(child_keys:, child_refs:)
        child_keys.zip(child_refs).each_with_object({}) do |(key, ref), memo|
          memo[key] = ref if key && ref
        end
      end

      def source_ticket_summary_for(success:, status:, summary:, parent_ref:, child_refs:, proposal:, evidence_path:)
        stage_state =
          if success == true
            "completed"
          elsif status == "gate_closed"
            "not attempted"
          else
            "blocked"
          end
        return source_ticket_summary_for_ja(stage_state: stage_state, success: success, status: status, summary: summary, parent_ref: parent_ref, child_refs: child_refs, proposal: proposal, evidence_path: evidence_path) if @system_comment_locale == "ja"

        lines = ["## Decomposition draft child creation: #{stage_state}", ""]
        lines << "- Summary: #{summary}"
        lines << "- Outcome: #{proposal_outcome(proposal)}" if proposal
        if proposal && proposal_outcome(proposal) == "needs_clarification"
          questions = Array(proposal["questions"]).map(&:to_s).reject(&:empty?)
          lines << ""
          lines << "### Questions"
          questions.each { |question| lines << "- #{question}" }
        end
        lines << ""
        lines << "### Details"
        lines << "- Generated parent: #{parent_ref || 'none'}"
        lines << "- Draft children: #{child_refs.empty? ? 'none' : child_refs.join(', ')}"
        lines << "- Evidence: #{evidence_path}"
        if success == true && status == "created"
          lines << ""
          lines.concat(accept_drafts_guidance_lines(parent_ref: parent_ref, child_refs: child_refs))
        end
        lines.join("\n")
      end

      def source_ticket_summary_for_ja(stage_state:, success:, status:, summary:, parent_ref:, child_refs:, proposal:, evidence_path:)
        lines = ["## デコンポジション子チケット作成: #{localized_stage_state(stage_state)}", ""]
        lines << "- 概要: #{summary}"
        lines << "- 結果: #{proposal_outcome(proposal)}" if proposal
        if proposal && proposal_outcome(proposal) == "needs_clarification"
          questions = Array(proposal["questions"]).map(&:to_s).reject(&:empty?)
          lines << ""
          lines << "### 確認事項"
          questions.each { |question| lines << "- #{question}" }
        end
        lines << ""
        lines << "### 詳細"
        lines << "- 生成された親チケット: #{parent_ref || 'なし'}"
        lines << "- 下書き子チケット: #{child_refs.empty? ? 'なし' : child_refs.join(', ')}"
        lines << "- 証跡: #{evidence_path}"
        if success == true && status == "created"
          lines << ""
          lines.concat(accept_drafts_guidance_lines_ja(parent_ref: parent_ref, child_refs: child_refs))
        end
        lines.join("\n")
      end

      def accept_drafts_guidance_lines(parent_ref:, child_refs:)
        all_command = parent_ref ? "a2o runtime decomposition accept-drafts #{parent_ref} --all" : nil
        ready_command = parent_ref ? "a2o runtime decomposition accept-drafts #{parent_ref} --ready" : nil
        child_command = parent_ref && child_refs.any? ? "a2o runtime decomposition accept-drafts #{parent_ref} --child #{child_refs.first}" : nil

        lines = [
          "### Accept draft children",
          "",
          "Draft children stay in Backlog until an operator accepts them and moves accepted work to To do.",
          "",
          "Next step with CLI:"
        ]
        lines << "- Accept all draft children: `#{all_command}`" if all_command
        lines << "- Accept one draft child: `#{child_command}`" if child_command
        lines << "- Accept draft children labeled `a2o:ready-child`: `#{ready_command}`" if ready_command
        lines << ""
        lines << "Parent automation: `accept-drafts` enables the generated parent by default; pass `--no-parent-auto` only when suppressing parent automation."
        lines
      end

      def accept_drafts_guidance_lines_ja(parent_ref:, child_refs:)
        all_command = parent_ref ? "a2o runtime decomposition accept-drafts #{parent_ref} --all" : nil
        ready_command = parent_ref ? "a2o runtime decomposition accept-drafts #{parent_ref} --ready" : nil
        child_command = parent_ref && child_refs.any? ? "a2o runtime decomposition accept-drafts #{parent_ref} --child #{child_refs.first}" : nil

        lines = [
          "### 下書き子チケットの承認",
          "",
          "下書き子チケットは、オペレーターが承認して To do レーンへ移動するまで Backlog に残ります。",
          "",
          "次のステップ（CLIで承認する場合）:"
        ]
        lines << "- すべての下書き子チケットを承認: `#{all_command}`" if all_command
        lines << "- 1件の下書き子チケットを承認: `#{child_command}`" if child_command
        lines << "- `a2o:ready-child` 付きの下書き子チケットを承認: `#{ready_command}`" if ready_command
        lines << ""
        lines << "親チケットの自動化: `accept-drafts` は既定で生成親チケットを有効化します。抑止する場合だけ `--no-parent-auto` を指定してください。"
        lines
      end

      def localized_stage_state(stage_state)
        {
          "completed" => "完了",
          "not attempted" => "未実行",
          "blocked" => "ブロック"
        }.fetch(stage_state, stage_state)
      end

      def normalize_system_comment_locale(locale)
        value = locale.to_s.strip
        %w[en ja].include?(value) ? value : "en"
      end

      def publish_source_ticket_summary(task:, body:)
        return false unless @publish_external_task_activity && task.external_task_id

        @publish_external_task_activity.publish(task_ref: task.ref, external_task_id: task.external_task_id, body: body)
        true
      end

      def writer_result_payload(result)
        return nil unless result

        {
          "success" => result.success?,
          "parent_ref" => result.respond_to?(:parent_ref) ? result.parent_ref : nil,
          "child_refs" => result.child_refs,
          "child_keys" => result.child_keys,
          "summary" => result.summary,
          "diagnostics" => result.diagnostics
        }
      end

      def evidence_path_for(task_ref, basename)
        File.join(@storage_dir, "decomposition-evidence", slugify(task_ref), basename)
      end

      def load_json(path)
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def proposal_outcome(proposal)
        value = proposal["outcome"].to_s.strip
        value.empty? ? "draft_children" : value
      end

      def blank?(value)
        value.to_s.strip.empty?
      end

      def non_empty_array?(value)
        value.is_a?(Array) && value.any? { |item| !blank?(item) }
      end

      def slugify(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
      end
    end
  end
end
