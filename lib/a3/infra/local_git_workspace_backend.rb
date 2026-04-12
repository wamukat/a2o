# frozen_string_literal: true

require "open3"
require "fileutils"

module A3
  module Infra
    class LocalGitWorkspaceBackend
      def git_repo?(source_root)
        ensure_safe_directory!(source_root)
        _stdout, _stderr, status = Open3.capture3("git", "-C", source_root.to_s, "rev-parse", "--git-common-dir")
        status.success?
      end

      def materialize(source_root:, destination:, ref:, create_branch_if_missing: false, reset_branch_to: nil)
        ensure_safe_directory!(source_root)
        assert_repo_identity!(source_root, source_root, label: "source_root")
        run_git!(source_root, "worktree", "prune")
        if create_branch_if_missing
          ensure_branch_ref!(source_root, ref, reset_to: reset_branch_to)
        elsif reset_branch_to
          reset_branch_ref!(source_root, ref, reset_to: reset_branch_to)
        end
        ensure_worktrees_dir!(source_root)
        run_git!(source_root, "worktree", "add", "--force", "--detach", destination.to_s, ref)
        ensure_safe_directory!(destination)
        assert_same_repository!(destination, source_root, label: "destination")
      end

      def ready?(source_root:, destination:, ref:)
        return false unless destination.exist?

        ensure_safe_directory!(source_root)
        ensure_safe_directory!(destination)
        return false unless repo_identity_matches?(source_root, source_root)
        return false unless same_repository?(destination, source_root)

        expected = rev_parse(source_root, ref)
        actual = rev_parse(destination, "HEAD")
        expected == actual
      rescue A3::Domain::ConfigurationError
        false
      end

      def remove(source_root:, destination:)
        return unless destination.exist?

        ensure_safe_directory!(source_root)
        ensure_safe_directory!(destination)
        unless registered_worktree?(source_root, destination)
          FileUtils.rm_rf(destination)
          return
        end

        run_git!(source_root, "worktree", "remove", "--force", destination.to_s)
        run_git!(source_root, "worktree", "prune")
      end

      private

      def rev_parse(root, ref)
        stdout, stderr, status = Open3.capture3("git", "-C", root.to_s, "rev-parse", ref.to_s)
        raise A3::Domain::ConfigurationError, "git rev-parse failed: #{stderr}" unless status.success?

        stdout.strip
      end

      def repo_identity_matches?(path, expected_root)
        git_toplevel(path) == normalize_path(expected_root.to_s)
      rescue A3::Domain::ConfigurationError
        false
      end

      def same_repository?(path, expected_root)
        git_common_dir(path) == git_common_dir(expected_root)
      rescue A3::Domain::ConfigurationError
        false
      end

      def assert_repo_identity!(path, expected_root, label:)
        actual = git_toplevel(path)
        normalized_expected = normalize_path(expected_root.to_s)
        return if actual == normalized_expected

        raise A3::Domain::ConfigurationError,
              "#{label} repo identity mismatch: expected=#{normalized_expected} actual=#{actual}"
      end

      def assert_same_repository!(path, expected_root, label:)
        actual = git_common_dir(path)
        expected = git_common_dir(expected_root)
        return if actual == expected

        raise A3::Domain::ConfigurationError,
              "#{label} repository mismatch: expected_common_dir=#{expected} actual_common_dir=#{actual}"
      end

      def git_toplevel(root)
        stdout, stderr, status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "--show-toplevel")
        raise A3::Domain::ConfigurationError, "git rev-parse --show-toplevel failed: #{stderr}" unless status.success?

        normalize_path(stdout.strip)
      end

      def git_common_dir(root)
        stdout, stderr, status = Open3.capture3("git", "-C", root.to_s, "rev-parse", "--git-common-dir")
        raise A3::Domain::ConfigurationError, "git rev-parse --git-common-dir failed: #{stderr}" unless status.success?

        common_dir = stdout.strip
        common_dir = File.expand_path(common_dir, root.to_s) unless Pathname(common_dir).absolute?
        normalize_path(common_dir)
      end

      def ensure_worktrees_dir!(root)
        FileUtils.mkdir_p(File.join(git_common_dir(root), "worktrees"))
      end

      def run_git!(root, *args)
        _stdout, stderr, status = Open3.capture3("git", "-C", root.to_s, *args)
        raise A3::Domain::ConfigurationError, "git #{args.join(' ')} failed: #{stderr}" unless status.success?
      end

      def registered_worktree?(root, destination)
        ensure_safe_directory!(root)
        stdout, stderr, status = Open3.capture3("git", "-C", root.to_s, "worktree", "list", "--porcelain")
        raise A3::Domain::ConfigurationError, "git worktree list failed: #{stderr}" unless status.success?

        listed_paths = stdout.each_line(chomp: true).each_with_object([]) do |line, paths|
          next unless line.start_with?("worktree ")

          paths << normalize_path(line.delete_prefix("worktree "))
        end
        listed_paths.include?(normalize_path(destination.to_s))
      end

      def ensure_safe_directory!(path)
        normalized = normalize_path(path.to_s)
        stdout, _stderr, status = Open3.capture3("git", "config", "--global", "--get-all", "safe.directory")
        return if status.success? && stdout.each_line(chomp: true).include?(normalized)

        _stdout, stderr, add_status = Open3.capture3("git", "config", "--global", "--add", "safe.directory", normalized)
        return if add_status.success?

        raise A3::Domain::ConfigurationError, "git config safe.directory failed: #{stderr}"
      end

      def normalize_path(path)
        File.realpath(path)
      rescue Errno::ENOENT, Errno::EACCES
        File.expand_path(path)
      end

      def ensure_branch_ref!(root, ref, reset_to: nil)
        rev_parse(root, ref)
        reset_branch_ref!(root, ref, reset_to: reset_to) if reset_to
      rescue A3::Domain::ConfigurationError
        branch_name = branch_name_for(ref)
        run_git!(root, "branch", "--force", branch_name, (reset_to || "HEAD"))
      end

      def reset_branch_ref!(root, ref, reset_to:)
        branch_name = branch_name_for(ref)
        previous_head = rev_parse(root, ref)
        target_head = rev_parse(root, reset_to)
        archive_branch_ref!(root, ref, previous_head) unless previous_head == target_head
        run_git!(root, "branch", "--force", branch_name, reset_to)
      end

      def branch_name_for(ref)
        ref_string = ref.to_s
        prefix = "refs/heads/"
        return ref_string.delete_prefix(prefix) if ref_string.start_with?(prefix)

        raise A3::Domain::ConfigurationError, "branch bootstrap requires refs/heads/* ref: #{ref}"
      end

      def archive_branch_ref!(root, ref, commit_sha)
        branch_name = branch_name_for(ref)
        archive_branch =
          if branch_name.start_with?("a3/")
            "a3/archive/#{branch_name.delete_prefix('a3/')}/#{commit_sha[0, 12]}"
          else
            "a3/archive/#{branch_name}/#{commit_sha[0, 12]}"
          end
        run_git!(root, "branch", "--force", archive_branch, commit_sha)
      end
    end
  end
end
