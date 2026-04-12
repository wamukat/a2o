# frozen_string_literal: true

require "json"
require "open3"

module A3
  module Infra
    class LocalMergeRunner
      class MergePublicationError < StandardError
        attr_reader :execution_result

        def initialize(execution_result)
          @execution_result = execution_result
          super(execution_result.summary)
        end
      end

      def run(merge_plan, workspace:)
        staged_updates = stage_merges(merge_plan, workspace)
        return staged_updates if staged_updates.is_a?(A3::Application::ExecutionResult)

        publish_updates(staged_updates, merge_plan)

        A3::Application::ExecutionResult.new(
          success: true,
          summary: "merged #{merge_plan.merge_source.source_ref} into #{merge_plan.integration_target.target_ref} for #{merge_plan.merge_slots.join(',')}"
        )
      rescue MergePublicationError => e
        e.execution_result
      end

      private

      def stage_merges(merge_plan, workspace)
        merge_plan.merge_slots.map do |merge_slot|
          slot_path = workspace.slot_paths[merge_slot]
          return missing_slot_result(merge_slot) unless slot_path

          target_before = ensure_target_ref(slot_path, merge_plan.integration_target)
          temp_ref = temporary_merge_ref(merge_plan, merge_slot)
          checkout = run_git(slot_path, "checkout", "-B", branch_name_for(temp_ref), merge_plan.integration_target.target_ref)
          return failure_result(checkout, merge_slot) unless checkout[:success]

          merge = run_git(slot_path, *merge_command(merge_plan))
          unless merge[:success]
            cleanup_temporary_ref(slot_path, temp_ref)
            return failure_result(merge, merge_slot)
          end

          merged_head = rev_parse(slot_path, "HEAD")
          detach = run_git(slot_path, "checkout", "--detach", merged_head)
          unless detach[:success]
            cleanup_temporary_ref(slot_path, temp_ref)
            return failure_result(detach, merge_slot)
          end
          {
            merge_slot: merge_slot,
            slot_path: slot_path,
            target_before: target_before,
            merged_head: merged_head,
            target_ref: merge_plan.integration_target.target_ref,
            temp_ref: temp_ref,
            root_sync: root_sync_metadata(slot_path, merge_plan.integration_target.target_ref)
          }
        end
      end

      def publish_updates(staged_updates, merge_plan)
        published = []
        publication_error = nil
        cleanup_failures = []

        begin
          staged_updates.each do |entry|
            update_ref = run_git(
              entry.fetch(:slot_path),
              "update-ref",
              entry.fetch(:target_ref),
              entry.fetch(:merged_head),
              entry.fetch(:target_before)
            )
            unless update_ref[:success]
              rollback_failures = rollback_published_updates(published)
              raise MergePublicationError.new(
                failure_result(
                  update_ref,
                  entry.fetch(:merge_slot),
                  extra_diagnostics: rollback_failure_diagnostics(rollback_failures)
                )
              )
            end

            parent_sync = sync_parent_owned_workspace_slot(entry)
            unless parent_sync[:success]
              rollback_failures = rollback_published_updates(published)
              raise MergePublicationError.new(
                failure_result(
                  parent_sync,
                  entry.fetch(:merge_slot),
                  extra_diagnostics: rollback_failure_diagnostics(rollback_failures)
                )
              )
            end

            published << entry
          end
          sync_root_repositories(published)
        rescue MergePublicationError => e
          publication_error = e
        ensure
          cleanup_failures = cleanup_temporary_refs(staged_updates)
        end

        raise augment_publication_error(publication_error, cleanup_failures) if publication_error
        raise cleanup_failure_error(cleanup_failures) unless cleanup_failures.empty?
      end

      def rollback_published_updates(published)
        published.reverse_each.each_with_object([]) do |entry, failures|
          rollback = run_git(
            entry.fetch(:slot_path),
            "update-ref",
            entry.fetch(:target_ref),
            entry.fetch(:target_before),
            entry.fetch(:merged_head)
          )
          next if rollback[:success]

          failures << rollback.merge("slot" => entry.fetch(:merge_slot).to_s)
        end
      end

      def rollback_failure_diagnostics(rollback_failures)
        return {} if rollback_failures.empty?

        { "rollback_failures" => rollback_failures }
      end

      def cleanup_temporary_refs(staged_updates)
        staged_updates.each_with_object([]) do |entry, failures|
          cleanup = cleanup_temporary_ref(entry.fetch(:slot_path), entry.fetch(:temp_ref))
          next if cleanup[:success]

          failures << cleanup.merge("slot" => entry.fetch(:merge_slot).to_s, "temp_ref" => entry.fetch(:temp_ref))
        end
      end

      def cleanup_temporary_ref(slot_path, temp_ref)
        run_git(slot_path, "update-ref", "-d", temp_ref)
      end

      def augment_publication_error(publication_error, cleanup_failures)
        return publication_error if cleanup_failures.empty?

        execution_result = publication_error.execution_result
        MergePublicationError.new(
          A3::Application::ExecutionResult.new(
            success: execution_result.success?,
            summary: execution_result.summary,
            failing_command: execution_result.failing_command,
            observed_state: execution_result.observed_state,
            diagnostics: execution_result.diagnostics.merge("cleanup_failures" => cleanup_failures)
          )
        )
      end

      def cleanup_failure_error(cleanup_failures)
        first_failure = cleanup_failures.first
        MergePublicationError.new(
          A3::Application::ExecutionResult.new(
            success: false,
            summary: "temporary merge ref cleanup failed (slot=#{first_failure.fetch('slot')})",
            failing_command: first_failure.fetch(:command),
            observed_state: "merge publication cleanup failed",
            diagnostics: { "cleanup_failures" => cleanup_failures }
          )
        )
      end

      def sync_root_repositories(published)
        published.each do |entry|
          sync = entry[:root_sync]
          next unless sync

          reset = run_git(sync.fetch(:repo_root), "reset", "--hard", "HEAD")
          next if reset[:success]

          raise MergePublicationError.new(
            A3::Application::ExecutionResult.new(
              success: false,
              summary: "#{reset[:summary]} (slot=#{entry.fetch(:merge_slot)})",
              failing_command: reset[:command],
              observed_state: "root repository sync failed",
              diagnostics: {
                "stdout" => reset[:stdout],
                "stderr" => reset[:stderr],
                "slot" => entry.fetch(:merge_slot).to_s,
                "repo_root" => sync.fetch(:repo_root).to_s
              }
            )
          )
        end
      end

      def sync_parent_owned_workspace_slot(entry)
        parent_slot = parent_workspace_slot_for(entry.fetch(:slot_path), entry.fetch(:target_ref))
        return { success: true } unless parent_slot

        run_git(parent_slot, "checkout", "--detach", entry.fetch(:target_ref))
      end

      def merge_command(merge_plan)
        case merge_plan.merge_policy
        when :ff_only
          ["merge", "--ff-only", merge_plan.merge_source.source_ref]
        when :ff_or_merge
          ["merge", "--no-edit", merge_plan.merge_source.source_ref]
        when :no_ff
          ["merge", "--no-ff", "--no-edit", merge_plan.merge_source.source_ref]
        else
          raise A3::Domain::ConfigurationError, "Unsupported merge policy: #{merge_plan.merge_policy}"
        end
      end

      def missing_slot_result(merge_slot)
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "missing merge slot #{merge_slot}",
          failing_command: "merge-slot-lookup",
          observed_state: "missing merge slot"
        )
      end

      def failure_result(command_result, merge_slot, extra_diagnostics: {})
        A3::Application::ExecutionResult.new(
          success: false,
          summary: "#{command_result[:summary]} (slot=#{merge_slot})",
          failing_command: command_result[:command],
          observed_state: "merge command failed",
          diagnostics: {
            "stdout" => command_result[:stdout],
            "stderr" => command_result[:stderr],
            "slot" => merge_slot.to_s
          }.merge(extra_diagnostics)
        )
      end

      def run_git(slot_path, *args)
        command = ["git", "-C", slot_path.to_s, *args]
        stdout, stderr, status = Open3.capture3(*command)
        {
          success: status.success?,
          stdout: stdout,
          stderr: stderr,
          command: command.join(" "),
          summary: stderr.empty? ? stdout.strip : stderr.strip
        }
      end

      def rev_parse(root, ref)
        stdout, stderr, status = Open3.capture3("git", "-C", root.to_s, "rev-parse", ref.to_s)
        raise A3::Domain::ConfigurationError, "git rev-parse failed: #{stderr}" unless status.success?

        stdout.strip
      end

      def root_sync_metadata(slot_path, target_ref)
        return nil unless target_ref.start_with?("refs/heads/")

        repo_root = repo_source_root_for(slot_path)
        return nil unless repo_root
        return nil unless current_branch(repo_root) == branch_name_for(target_ref)
        return nil unless clean_worktree?(repo_root)

        { repo_root: repo_root }
      end

      def parent_workspace_slot_for(slot_path, target_ref)
        prefix = "refs/heads/a3/parent/"
        return nil unless target_ref.start_with?(prefix)

        parent_slug = target_ref.delete_prefix(prefix)
        normalized = File.expand_path(slot_path.to_s)
        marker = File.join("workspaces", parent_slug, "children")
        marker_index = normalized.index(marker)
        return nil unless marker_index

        relative = normalized[(marker_index + marker.length + 1)..]
        parts = relative.to_s.split(File::SEPARATOR)
        return nil if parts.length < 3

        repo_dir = parts.last
        parent_slot = File.join(normalized[0...marker_index], "workspaces", parent_slug, "runtime_workspace", repo_dir)
        return nil unless File.directory?(parent_slot)

        parent_slot
      end

      def repo_source_root_for(slot_path)
        metadata_path = File.join(slot_path.to_s, ".a3", "slot.json")
        return nil unless File.file?(metadata_path)

        payload = JSON.parse(File.read(metadata_path))
        repo_root = payload["repo_source_root"].to_s.strip
        return nil if repo_root.empty?

        repo_root
      rescue JSON::ParserError
        nil
      end

      def current_branch(repo_root)
        stdout, _stderr, status = Open3.capture3("git", "-C", repo_root.to_s, "symbolic-ref", "--quiet", "--short", "HEAD")
        return nil unless status.success?

        stdout.strip
      end

      def clean_worktree?(repo_root)
        stdout, _stderr, status = Open3.capture3(
          "git", "-C", repo_root.to_s, "status", "--porcelain", "--untracked-files=all"
        )
        return false unless status.success?

        stdout.strip.empty?
      end

      def ensure_target_ref(slot_path, integration_target)
        rev_parse(slot_path, integration_target.target_ref)
      rescue A3::Domain::ConfigurationError
        bootstrap_target_ref(slot_path, integration_target)
        rev_parse(slot_path, integration_target.target_ref)
      end

      def bootstrap_target_ref(slot_path, integration_target)
        case integration_target.target_ref
        when /\Arefs\/heads\/a3\/parent\//
          bootstrap_ref = integration_target.bootstrap_ref
          raise A3::Domain::ConfigurationError, "missing bootstrap_ref for #{integration_target.target_ref}" if bootstrap_ref.nil? || bootstrap_ref.to_s.strip.empty?

          live_head = rev_parse(slot_path, bootstrap_ref)
          bootstrap = run_git(slot_path, "update-ref", integration_target.target_ref, live_head)
          return if bootstrap[:success]

          raise A3::Domain::ConfigurationError, "git update-ref failed: #{bootstrap[:stderr]}"
        else
          raise A3::Domain::ConfigurationError, "git rev-parse failed: missing target ref #{integration_target.target_ref}"
        end
      end

      def temporary_merge_ref(merge_plan, merge_slot)
        task_key = merge_plan.task_ref.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
        run_key = merge_plan.run_ref.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
        "refs/heads/a3/merge-publication/#{task_key}/#{run_key}/#{merge_slot}"
      end

      def branch_name_for(ref)
        ref.to_s.delete_prefix("refs/heads/")
      end
    end
  end
end
