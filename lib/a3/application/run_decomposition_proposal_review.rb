# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"

module A3
  module Application
    class RunDecompositionProposalReview
      Result = Struct.new(:success, :summary, :disposition, :critical_findings, :review_results, :request_path, :evidence_path, :source_ticket_summary, keyword_init: true)

      def initialize(storage_dir:, project_root: Dir.pwd, process_runner: nil, publish_external_task_activity: nil, clock: -> { Time.now.utc }, host_shared_root: nil, container_shared_root: nil, command_workspace_dir: nil)
        @storage_dir = storage_dir
        @command_workspace_dir = command_workspace_dir
        @project_root = project_root
        @process_runner = process_runner || method(:run_process)
        @publish_external_task_activity = publish_external_task_activity
        @clock = clock
        @host_shared_root = clean_root(host_shared_root)
        @container_shared_root = clean_root(container_shared_root)
      end

      def call(task:, project_surface:, proposal_evidence_path: nil)
        commands = project_surface.decomposition_review_commands
        raise A3::Domain::ConfigurationError, "project.yaml runtime.decomposition.review.commands must be provided" if commands.empty?

        proposal_evidence_path ||= default_proposal_evidence_path(task.ref)
        proposal_evidence = load_json(proposal_evidence_path)
        proposal_errors = proposal_evidence_errors(proposal_evidence)
        workspace_root = prepare_workspace_root(task.ref)
        request_path = File.join(workspace_root, ".a2o", "decomposition-review-request.json")
        FileUtils.mkdir_p(File.dirname(request_path))
        request = request_payload(task: task, proposal_evidence_path: command_path(proposal_evidence_path), proposal_evidence: proposal_evidence, workspace_root: command_path(workspace_root))
        write_json(request_path, request)

        review_results = commands.map.with_index do |command, index|
          run_reviewer(command: resolve_command(command), index: index, workspace_root: workspace_root, request_path: request_path)
        end
        critical_findings = proposal_errors.map { |error| critical_finding(error) }
        critical_findings.concat(review_results.flat_map { |result| result.fetch("findings") }.select { |finding| finding.fetch("severity") == "critical" })
        disposition = critical_findings.empty? ? "eligible" : "blocked"
        success = disposition == "eligible"
        summary = success ? "proposal review eligible for next gate" : "proposal review blocked by #{critical_findings.size} critical finding(s)"
        source_ticket_summary = source_ticket_summary_for(summary: summary, disposition: disposition, critical_findings: critical_findings, review_results: review_results)
        evidence_path = persist_evidence(
          task: task,
          request: request,
          review_results: review_results,
          disposition: disposition,
          success: success,
          summary: summary,
          critical_findings: critical_findings,
          request_path: request_path,
          workspace_root: workspace_root,
          source_ticket_summary: source_ticket_summary
        )
        publish_source_ticket_summary(task: task, body: source_ticket_summary)

        Result.new(
          success: success,
          summary: summary,
          disposition: disposition,
          critical_findings: critical_findings,
          review_results: review_results,
          request_path: request_path,
          evidence_path: evidence_path,
          source_ticket_summary: source_ticket_summary
        )
      end

      private

      CommandStatus = Struct.new(:success?, :exitstatus)

      def run_reviewer(command:, index:, workspace_root:, request_path:)
        result_path = File.join(workspace_root, ".a2o", "decomposition-review-result-#{index + 1}.json")
        FileUtils.rm_f(result_path)
        stdout, stderr, status = @process_runner.call(
          command,
          chdir: command_path(workspace_root),
          env: {
            "A2O_DECOMPOSITION_REVIEW_REQUEST_PATH" => command_path(request_path),
            "A2O_DECOMPOSITION_REVIEW_RESULT_PATH" => command_path(result_path),
            "A2O_WORKSPACE_ROOT" => command_path(workspace_root),
            "A2O_ROOT_DIR" => command_path(@project_root)
          }
        )
        raw_result = load_json(result_path)
        normalize_result(command: command, status: status, stdout: stdout, stderr: stderr, raw_result: raw_result)
      rescue SystemCallError => e
        normalize_result(command: command, status: CommandStatus.new(false, nil), stdout: "", stderr: e.message, raw_result: nil)
      end

      def normalize_result(command:, status:, stdout:, stderr:, raw_result:)
        findings = []
        valid_result = status.success? && raw_result.is_a?(Hash) && non_empty_string?(raw_result["summary"]) && raw_result["findings"].is_a?(Array)
        if raw_result.is_a?(Hash) && raw_result["findings"].is_a?(Array)
          findings = raw_result["findings"].map { |finding| normalize_finding(finding) }
        end
        unless valid_result
          findings << {
            "severity" => "critical",
            "summary" => invalid_review_summary(status: status, raw_result: raw_result)
          }
        end
        {
          "command" => command,
          "success" => valid_result,
          "summary" => raw_result.is_a?(Hash) ? raw_result["summary"].to_s : "",
          "findings" => findings,
          "stdout" => stdout,
          "stderr" => stderr,
          "exit_status" => status.exitstatus
        }
      end

      def invalid_review_summary(status:, raw_result:)
        return "review command failed to launch" if status.exitstatus.nil?
        return "review command failed with exit #{status.exitstatus}" unless status.success?
        return "review result JSON is missing or invalid" unless raw_result.is_a?(Hash)
        return "review result summary must be a non-empty string" unless non_empty_string?(raw_result["summary"])
        return "review result findings must be an array" unless raw_result["findings"].is_a?(Array)

        "review result JSON is invalid"
      end

      def normalize_finding(finding)
        payload = finding.is_a?(Hash) ? finding : {}
        severity = payload["severity"].to_s
        severity = "critical" unless %w[critical major minor info].include?(severity)
        {
          "severity" => severity,
          "summary" => payload["summary"].to_s.strip.empty? ? "review finding" : payload["summary"].to_s,
          "details" => payload["details"].to_s
        }
      end

      def request_payload(task:, proposal_evidence_path:, proposal_evidence:, workspace_root:)
        {
          "task_ref" => task.ref,
          "task_kind" => task.kind.to_s,
          "labels" => task.labels,
          "proposal_evidence_path" => proposal_evidence_path,
          "proposal_evidence" => proposal_evidence,
          "workspace_root" => workspace_root
        }
      end

      def proposal_evidence_errors(proposal_evidence)
        return ["proposal evidence is missing or invalid"] unless proposal_evidence.is_a?(Hash)
        return ["proposal evidence did not succeed"] unless proposal_evidence["success"] == true

        proposal = proposal_evidence["proposal"]
        errors = []
        errors << "proposal fingerprint is missing" unless non_empty_string?(proposal_evidence["proposal_fingerprint"]) || (proposal.is_a?(Hash) && non_empty_string?(proposal["proposal_fingerprint"]))
        errors << "proposal children are missing" unless proposal.is_a?(Hash) && proposal["children"].is_a?(Array) && proposal["children"].any?
        errors
      end

      def critical_finding(summary)
        { "severity" => "critical", "summary" => summary, "details" => "" }
      end

      def source_ticket_summary_for(summary:, disposition:, critical_findings:, review_results:)
        lines = ["Decomposition proposal review: #{summary}", "Disposition: #{disposition}", "Reviewers: #{review_results.size}"]
        critical_findings.each { |finding| lines << "Critical: #{finding.fetch('summary')}" }
        lines.join("\n")
      end

      def persist_evidence(task:, request:, review_results:, disposition:, success:, summary:, critical_findings:, request_path:, workspace_root:, source_ticket_summary:)
        evidence_dir = File.join(@storage_dir, "decomposition-evidence", slugify(task.ref))
        FileUtils.mkdir_p(evidence_dir)
        evidence_path = File.join(evidence_dir, "proposal-review.json")
        write_json(
          evidence_path,
          {
            "task_ref" => task.ref,
            "phase" => "proposal_review",
            "success" => success,
            "disposition" => disposition,
            "summary" => summary,
            "critical_findings" => critical_findings,
            "review_results" => review_results,
            "request" => request,
            "request_path" => request_path,
            "workspace_root" => workspace_root,
            "source_ticket_summary" => source_ticket_summary
          }
        )
        evidence_path
      end

      def publish_source_ticket_summary(task:, body:)
        return false unless @publish_external_task_activity && task.external_task_id

        @publish_external_task_activity.publish(task_ref: task.ref, external_task_id: task.external_task_id, body: body)
        true
      end

      def non_empty_string?(value)
        value.is_a?(String) && !value.strip.empty?
      end

      def prepare_workspace_root(task_ref)
        base_dir = File.join(@command_workspace_dir || File.join(@storage_dir, "decomposition-workspaces"), slugify(task_ref))
        FileUtils.mkdir_p(base_dir)
        Dir.mktmpdir("proposal-review-#{@clock.call.strftime('%Y%m%d%H%M%S')}-", base_dir)
      end

      def default_proposal_evidence_path(task_ref)
        File.join(@storage_dir, "decomposition-evidence", slugify(task_ref), "proposal.json")
      end

      def load_json(path)
        return nil unless path && File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def resolve_command(command)
        first, *rest = command
        resolved_first = first.include?(File::SEPARATOR) && Pathname.new(first).relative? ? command_path(File.expand_path(first, @project_root)) : first
        [resolved_first, *rest]
      end

      def write_json(path, payload)
        File.write(path, "#{JSON.pretty_generate(payload)}\n")
      end

      def command_path(path)
        value = path.to_s
        return value if value.empty? || !@host_shared_root || !@container_shared_root
        return @host_shared_root if value == @container_shared_root
        return File.join(@host_shared_root, value.delete_prefix("#{@container_shared_root}/")) if value.start_with?("#{@container_shared_root}/")

        value
      end

      def clean_root(path)
        value = path.to_s.sub(%r{/+\z}, "")
        value.empty? ? nil : value
      end

      def slugify(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
      end

      def run_process(command, chdir:, env:)
        stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
        [stdout, stderr, status]
      end
    end
  end
end
