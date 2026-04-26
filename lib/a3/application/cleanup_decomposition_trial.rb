# frozen_string_literal: true

require "fileutils"
require "json"

module A3
  module Application
    class CleanupDecompositionTrial
      EvidenceRecord = Struct.new(:path, :phase, :status, :success, :proposal_fingerprint, :child_refs, :child_keys, keyword_init: true)
      TargetPath = Struct.new(:kind, :path, :exists, keyword_init: true)
      Result = Struct.new(:task_ref, :mode, :target_paths, :deleted_paths, :evidence_records, :proposal_fingerprint, :child_refs, :child_keys, keyword_init: true)

      def initialize(storage_dir:)
        @storage_dir = File.expand_path(storage_dir)
      end

      def call(task_ref:, apply: false)
        slug = slugify(task_ref)
        target_paths = [
          TargetPath.new(kind: "evidence_dir", path: safe_child_path("decomposition-evidence", slug), exists: false),
          TargetPath.new(kind: "workspace_dir", path: safe_child_path("decomposition-workspaces", slug), exists: false)
        ].map { |target| target.exists = File.exist?(target.path); target }
        target_paths.each { |target| assert_safe_target!(target.path) if target.exists }
        evidence_records = collect_evidence_records(target_paths.first.path)
        deleted_paths = apply ? delete_existing_targets(target_paths) : []

        Result.new(
          task_ref: task_ref,
          mode: apply ? "apply" : "dry-run",
          target_paths: target_paths,
          deleted_paths: deleted_paths,
          evidence_records: evidence_records,
          proposal_fingerprint: evidence_records.map(&:proposal_fingerprint).compact.first,
          child_refs: evidence_records.flat_map(&:child_refs).uniq,
          child_keys: evidence_records.flat_map(&:child_keys).uniq
        )
      end

      private

      def collect_evidence_records(evidence_dir)
        return [] unless File.directory?(evidence_dir)

        Dir.glob(File.join(evidence_dir, "**", "*.json")).sort.filter_map do |path|
          next if symlink_in_path?(File.expand_path(path))

          payload = load_json(path)
          next unless payload.is_a?(Hash)

          EvidenceRecord.new(
            path: path,
            phase: payload["phase"] || phase_from_path(path),
            status: payload["status"] || payload["disposition"],
            success: payload["success"],
            proposal_fingerprint: payload["proposal_fingerprint"] || payload.dig("proposal", "proposal_fingerprint"),
            child_refs: child_refs_for(payload),
            child_keys: child_keys_for(payload)
          )
        end
      end

      def delete_existing_targets(target_paths)
        target_paths.filter_map do |target|
          next unless target.exists

          assert_safe_target!(target.path)
          FileUtils.rm_rf(target.path)
          target.path
        end
      end

      def safe_child_path(kind, slug)
        path = File.expand_path(File.join(@storage_dir, kind, slug))
        base = File.expand_path(File.join(@storage_dir, kind))
        unless path.start_with?("#{base}#{File::SEPARATOR}") && File.basename(path) == slug
          raise ArgumentError, "unsafe decomposition cleanup path: #{path}"
        end

        path
      end

      def assert_safe_target!(path)
        expanded = File.expand_path(path)
        allowed_bases = %w[decomposition-evidence decomposition-workspaces].map do |kind|
          File.expand_path(File.join(@storage_dir, kind))
        end
        unless allowed_bases.any? { |base| expanded.start_with?("#{base}#{File::SEPARATOR}") }
          raise ArgumentError, "unsafe decomposition cleanup target: #{path}"
        end
        if symlink_in_path?(expanded)
          raise ArgumentError, "unsafe decomposition cleanup target contains symlink: #{path}"
        end

        true
      end

      def load_json(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      end

      def symlink_in_path?(path)
        storage = File.expand_path(@storage_dir)
        current = path
        while current.start_with?("#{storage}#{File::SEPARATOR}") || current == storage
          return true if File.symlink?(current)
          break if current == storage

          current = File.dirname(current)
        end
        false
      end

      def child_refs_for(payload)
        Array(payload["child_refs"]) +
          Array(payload.dig("writer_result", "child_refs")) +
          proposal_children(payload).filter_map { |child| child["child_ref"] || child["ref"] }
      end

      def child_keys_for(payload)
        Array(payload["child_keys"]) +
          Array(payload.dig("writer_result", "child_keys")) +
          proposal_children(payload).filter_map { |child| child["child_key"] }
      end

      def proposal_children(payload)
        children = payload.dig("proposal", "children")
        children.is_a?(Array) ? children.grep(Hash) : []
      end

      def phase_from_path(path)
        File.basename(path, ".json").tr("-", "_")
      end

      def slugify(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, "-")
      end
    end
  end
end
