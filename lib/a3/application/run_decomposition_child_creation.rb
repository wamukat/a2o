# frozen_string_literal: true

require "fileutils"
require "json"

module A3
  module Application
    class RunDecompositionChildCreation
      Result = Struct.new(:success, :status, :summary, :child_refs, :child_keys, :evidence_path, :source_ticket_summary, :source_ticket_summary_published, keyword_init: true)

      def initialize(storage_dir:, child_writer:, publish_external_task_activity: nil)
        @storage_dir = storage_dir
        @child_writer = child_writer
        @publish_external_task_activity = publish_external_task_activity
      end

      def call(task:, gate:, proposal_evidence_path: nil, review_evidence_path: nil)
        proposal_evidence_path ||= evidence_path_for(task.ref, "proposal.json")
        review_evidence_path ||= evidence_path_for(task.ref, "proposal-review.json")
        proposal_evidence = load_json(proposal_evidence_path)
        review_evidence = load_json(review_evidence_path)
        return gate_closed_result(task: task, proposal_evidence: proposal_evidence, review_evidence: review_evidence) unless gate

        validation_errors = validation_errors_for(proposal_evidence: proposal_evidence, review_evidence: review_evidence)
        return blocked_result(task: task, summary: validation_errors.join("; "), proposal_evidence: proposal_evidence, review_evidence: review_evidence) unless validation_errors.empty?

        write_result = @child_writer.call(
          parent_task_ref: task.ref,
          parent_external_task_id: task.external_task_id,
          proposal_evidence: proposal_evidence
        )
        if write_result.success?
          persist_evidence(
            task: task,
            success: true,
            status: "created",
            summary: "created or reconciled #{write_result.child_refs.size} decomposition child ticket(s)",
            proposal_evidence: proposal_evidence,
            review_evidence: review_evidence,
            writer_result: writer_result_payload(write_result)
          )
        else
          blocked_result(
            task: task,
            summary: write_result.summary || "decomposition child creation failed",
            proposal_evidence: proposal_evidence,
            review_evidence: review_evidence,
            writer_result: writer_result_payload(write_result)
          )
        end
      end

      private

      def validation_errors_for(proposal_evidence:, review_evidence:)
        errors = []
        errors << "proposal evidence did not succeed" unless proposal_evidence.is_a?(Hash) && proposal_evidence["success"] == true
        proposal = proposal_evidence.is_a?(Hash) ? proposal_evidence["proposal"] : nil
        errors << "proposal children are missing" unless proposal.is_a?(Hash) && proposal["children"].is_a?(Array) && proposal["children"].any?
        errors << "proposal review is not eligible" unless review_evidence.is_a?(Hash) && review_evidence["disposition"] == "eligible"
        if proposal_evidence.is_a?(Hash) && review_evidence.is_a?(Hash)
          proposal_fingerprint = proposal_evidence["proposal_fingerprint"]
          reviewed_fingerprint = review_evidence.dig("request", "proposal_evidence", "proposal_fingerprint") || review_evidence["proposal_fingerprint"]
          errors << "proposal review fingerprint does not match proposal" unless reviewed_fingerprint == proposal_fingerprint
        end
        errors
      end

      def blocked_result(task:, summary:, proposal_evidence: nil, review_evidence: nil, writer_result: nil)
        persist_evidence(
          task: task,
          success: false,
          status: "blocked",
          summary: summary,
          proposal_evidence: proposal_evidence,
          review_evidence: review_evidence,
          writer_result: writer_result
        )
      end

      def gate_closed_result(task:, proposal_evidence:, review_evidence:)
        persist_evidence(
          task: task,
          success: nil,
          status: "gate_closed",
          summary: "decomposition child creation gate is closed",
          proposal_evidence: proposal_evidence,
          review_evidence: review_evidence,
          writer_result: nil
        )
      end

      def persist_evidence(task:, success:, status:, summary:, proposal_evidence:, review_evidence:, writer_result:)
        evidence_dir = File.join(@storage_dir, "decomposition-evidence", slugify(task.ref))
        FileUtils.mkdir_p(evidence_dir)
        path = File.join(evidence_dir, "child-creation.json")
        child_refs = writer_result ? Array(writer_result["child_refs"]) : []
        child_keys = writer_result ? Array(writer_result["child_keys"]) : []
        source_ticket_summary = source_ticket_summary_for(
          success: success,
          status: status,
          summary: summary,
          child_refs: child_refs,
          evidence_path: path
        )
        File.write(
          path,
          "#{JSON.pretty_generate(
            "task_ref" => task.ref,
            "phase" => "child_creation",
            "success" => success,
            "status" => status,
            "summary" => summary,
            "proposal_fingerprint" => proposal_evidence && proposal_evidence["proposal_fingerprint"],
            "review_disposition" => review_evidence && review_evidence["disposition"],
            "child_refs" => child_refs,
            "child_keys" => child_keys,
            "child_refs_by_key" => child_refs_by_key(child_keys: child_keys, child_refs: child_refs),
            "source_ticket_summary" => source_ticket_summary,
            "proposal_evidence" => proposal_evidence,
            "review_evidence" => review_evidence,
            "writer_result" => writer_result
          )}\n"
        )
        summary_published = publish_source_ticket_summary(task: task, body: source_ticket_summary)
        Result.new(
          success: success,
          status: status,
          summary: summary,
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

      def source_ticket_summary_for(success:, status:, summary:, child_refs:, evidence_path:)
        stage_state =
          if success == true
            "completed"
          elsif status == "gate_closed"
            "not attempted"
          else
            "blocked"
          end
        lines = ["Decomposition draft child creation: #{stage_state}"]
        lines << "Summary: #{summary}"
        lines << "Draft children: #{child_refs.empty? ? 'none' : child_refs.join(', ')}"
        if success == true
          lines << "Accept: add trigger:auto-implement to a draft child when it is ready for implementation."
          lines << "Parent automation: add trigger:auto-parent to the source parent after accepted child work is ready."
        end
        lines << "Evidence: #{evidence_path}"
        lines.join("\n")
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

      def slugify(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
      end
    end
  end
end
