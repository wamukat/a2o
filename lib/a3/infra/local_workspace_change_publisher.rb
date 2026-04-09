# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

module A3
  module Infra
    class LocalWorkspaceChangePublisher
      COMMITTER_NAME = "A3-v2".freeze
      COMMITTER_EMAIL = "a3-v2@local".freeze

      def publish(run:, workspace:, execution:, remediation_commands: [])
        return skipped_result("phase #{run.phase} does not publish workspace changes") unless run.phase.to_sym == :implementation
        return skipped_result("workspace kind #{workspace.workspace_kind} does not publish changes") unless workspace.workspace_kind.to_sym == :ticket_workspace
        return skipped_result("source type #{run.source_descriptor.source_type} does not publish changes") unless run.source_descriptor.source_type.to_sym == :branch_head

        allowlisted_files = extract_allowlisted_files(execution)
        remediation_summaries = []
        published_slots = workspace.slot_paths.each_with_object([]) do |(slot_name, slot_path), entries|
          next unless git_repo?(slot_path)

          source_ref = source_ref_for(slot_path)
          next if source_ref.nil?

          actual_changes = changed_paths(slot_path)
          next if actual_changes.empty?

          allowed_paths = normalized_allowlist_for(slot_name, allowlisted_files)
          assert_publishable_changes!(slot_name, actual_changes, allowed_paths)
          remediation_summaries.concat(run_remediation_commands!(slot_path, remediation_commands))
          remediated_changes = changed_paths(slot_path)
          discard_unallowlisted_changes!(slot_path, actual_changes, remediated_changes, allowed_paths)
          actual_changes = changed_paths(slot_path)
          assert_publishable_changes!(slot_name, actual_changes, allowed_paths)
          before_head = rev_parse(slot_path, source_ref)
          stage_paths!(slot_path, allowed_paths)
          run_git!(
            slot_path,
            "-c", "user.name=#{COMMITTER_NAME}",
            "-c", "user.email=#{COMMITTER_EMAIL}",
            "commit", "-m", "A3-v2 direct canary update for #{run.task_ref}"
          )
          after_head = rev_parse(slot_path, "HEAD")
          run_git!(slot_path, "update-ref", source_ref, after_head, before_head)
          entries << {
            "slot" => slot_name.to_s,
            "source_ref" => source_ref,
            "before_head" => before_head,
            "after_head" => after_head,
          }
        end

        if published_slots.empty?
          skipped_result("no workspace changes to publish", diagnostics: { "published_slots" => [] })
        else
          A3::Application::ExecutionResult.new(
            success: true,
            summary: ([*remediation_summaries, "published workspace changes for #{published_slots.map { |entry| entry.fetch("slot") }.join(',')}"]).join("; "),
            diagnostics: { "published_slots" => published_slots, "remediation_commands" => remediation_summaries }
          )
        end
      rescue A3::Domain::ConfigurationError => e
        A3::Application::ExecutionResult.new(
          success: false,
          summary: e.message,
          failing_command: "workspace_change_publication",
          observed_state: "workspace publication failed"
        )
      end

      private

      def skipped_result(summary, diagnostics: {})
        A3::Application::ExecutionResult.new(
          success: true,
          summary: summary,
          diagnostics: diagnostics
        )
      end

      def git_repo?(slot_path)
        _stdout, _stderr, status = Open3.capture3("git", "-C", slot_path.to_s, "rev-parse", "--is-inside-work-tree")
        status.success?
      end

      def source_ref_for(slot_path)
        metadata_path = File.join(slot_path.to_s, ".a3", "slot.json")
        return nil unless File.file?(metadata_path)

        JSON.parse(File.read(metadata_path)).fetch("source_ref")
      end

      def changes_present?(slot_path)
        stdout, _stderr, status = Open3.capture3("git", "-C", slot_path.to_s, "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).a3")
        raise A3::Domain::ConfigurationError, "git status failed for #{slot_path}" unless status.success?

        !stdout.strip.empty?
      end

      def changed_paths(slot_path)
        stdout, stderr, status = Open3.capture3(
          "git", "-C", slot_path.to_s, "status", "--porcelain", "--untracked-files=all", "--", ".", ":(exclude).a3"
        )
        raise A3::Domain::ConfigurationError, "git status failed: #{stderr}" unless status.success?

        stdout.each_line.map do |line|
          path = line[3..]&.strip
          next if path.nil? || path.empty?

          path.include?(" -> ") ? path.split(" -> ", 2).last : path
        end.compact.uniq.sort
      end

      def extract_allowlisted_files(execution)
        return {} unless execution.response_bundle.is_a?(Hash)

        changed_files = execution.response_bundle["changed_files"]
        return {} unless changed_files.is_a?(Hash)

        changed_files
      end

      def normalized_allowlist_for(slot_name, allowlisted_files)
        paths = Array(allowlisted_files.fetch(slot_name.to_s, []))
        paths.map do |path|
          normalized_path = path.to_s.strip
          raise A3::Domain::ConfigurationError, "changed_files for #{slot_name} contains an empty path" if normalized_path.empty?
          raise A3::Domain::ConfigurationError, "changed_files for #{slot_name} must be relative: #{normalized_path}" if normalized_path.start_with?("/")
          raise A3::Domain::ConfigurationError, "changed_files for #{slot_name} must stay within the slot: #{normalized_path}" if normalized_path.split("/").include?("..")
          raise A3::Domain::ConfigurationError, "changed_files for #{slot_name} must not publish .a3 internals: #{normalized_path}" if normalized_path == ".a3" || normalized_path.start_with?(".a3/")

          normalized_path
        end.uniq.sort
      end

      def assert_publishable_changes!(slot_name, actual_changes, allowed_paths)
        raise A3::Domain::ConfigurationError, "worker response missing changed_files for slot #{slot_name}" if allowed_paths.empty?

        unexpected_paths = actual_changes - allowed_paths
        return if unexpected_paths.empty?

        raise A3::Domain::ConfigurationError,
              "worker response omitted changed_files for slot #{slot_name}: #{unexpected_paths.join(', ')}"
      end

      def discard_unallowlisted_changes!(slot_path, baseline_changes, actual_changes, allowed_paths)
        unexpected_paths = (actual_changes - baseline_changes) - allowed_paths
        unexpected_paths.each do |path|
          if tracked_path?(slot_path, path)
            run_git!(slot_path, "restore", "--source=HEAD", "--staged", "--worktree", "--", path)
          else
            FileUtils.rm_rf(File.join(slot_path.to_s, path))
          end
        end
      end

      def stage_paths!(slot_path, allowed_paths)
        run_git!(slot_path, "add", "--all", "--", *allowed_paths)
      end

      def rev_parse(slot_path, ref)
        stdout, stderr, status = Open3.capture3("git", "-C", slot_path.to_s, "rev-parse", ref.to_s)
        raise A3::Domain::ConfigurationError, "git rev-parse failed: #{stderr}" unless status.success?

        stdout.strip
      end

      def run_git!(slot_path, *args)
        _stdout, stderr, status = Open3.capture3("git", "-C", slot_path.to_s, *args)
        raise A3::Domain::ConfigurationError, "git #{args.join(' ')} failed: #{stderr}" unless status.success?
      end

      def tracked_path?(slot_path, path)
        _stdout, _stderr, status = Open3.capture3("git", "-C", slot_path.to_s, "ls-files", "--error-unmatch", "--", path)
        status.success?
      end

      def run_remediation_commands!(slot_path, commands)
        Array(commands).each_with_object([]) do |command, summaries|
          command = command.to_s.strip
          next if command.empty?

          stdout, stderr, status = Open3.capture3(command, chdir: slot_path.to_s)
          unless status.success?
            detail = [stderr.to_s.strip, stdout.to_s.strip].find { |value| !value.empty? } || "exit #{status.exitstatus}"
            raise A3::Domain::ConfigurationError,
                  "remediation command failed in #{slot_path}: #{command} (#{detail})"
          end

          summaries << "#{command} ok"
        end
      end
    end
  end
end
