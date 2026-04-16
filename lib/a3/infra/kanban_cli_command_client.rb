# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require "tmpdir"

module A3
  module Infra
    class KanbanCommandClient
      def self.subprocess(command_argv:, project:, working_dir: nil)
        SubprocessKanbanCommandClient.new(command_argv: command_argv, project: project, working_dir: working_dir)
      end

      attr_reader :project

      def initialize(project:)
        @project = project.to_s
      end

      def run_json_command(*_args)
        raise NotImplementedError, "#{self.class} must implement run_json_command"
      end

      def run_command(*_args)
        raise NotImplementedError, "#{self.class} must implement run_command"
      end

      def run_json_command_with_text_file_option(*args, option_name:, text:, file_option_name: "#{option_name}-file", tempfile_prefix: "a3-kanban-text")
        with_text_file(text, tempfile_prefix: tempfile_prefix) do |path|
          run_json_command(*args, file_option_name, path)
        end
      end

      def run_command_with_text_file_option(*args, option_name:, text:, file_option_name: "#{option_name}-file", tempfile_prefix: "a3-kanban-text")
        with_text_file(text, tempfile_prefix: tempfile_prefix) do |path|
          run_command(*args, file_option_name, path)
        end
      end

      def fetch_task_by_id(task_id)
        payload = run_json_command("task-get", "--project", @project, "--task-id", Integer(task_id).to_s)
        raise A3::Domain::ConfigurationError, "kanban task-get must return an object" unless payload.is_a?(Hash)

        payload
      end

      def fetch_task_by_ref(task_ref)
        payload = run_json_command("task-get", "--project", @project, "--task", String(task_ref))
        raise A3::Domain::ConfigurationError, "kanban task-get must return an object" unless payload.is_a?(Hash)

        payload
      end

      def load_task_labels(task_id, include_project: false)
        args = ["task-label-list"]
        args += ["--project", @project] if include_project
        args += ["--task-id", Integer(task_id).to_s]
        payload = run_json_command(*args)
        raise A3::Domain::ConfigurationError, "kanban task-label-list must return an array" unless payload.is_a?(Array)

        payload
      end

      def resolve_task_id(task_ref, external_task_id:, canonical_required: true)
        return Integer(external_task_id) if external_task_id

        value = String(task_ref).strip
        canonical = /\A.+?#\d+\z/.match?(value)
        raise A3::Domain::ConfigurationError, "kanban task ref must be canonical Project#N: #{task_ref}" if canonical_required && !canonical
        return nil unless canonical

        Integer(fetch_task_by_ref(value).fetch("id"))
      rescue ArgumentError
        nil
      end

      private

      def with_text_file(text, tempfile_prefix:)
        Tempfile.create([tempfile_prefix, ".md"], tempfile_dir) do |file|
          file.write(String(text))
          file.flush
          yield file.path
        end
      end

      def tempfile_dir
        Dir.tmpdir
      end
    end

    class SubprocessKanbanCommandClient < KanbanCommandClient
      def initialize(command_argv:, project:, working_dir: nil)
        super(project: project)
        @command_argv = Array(command_argv).map(&:to_s).freeze
        raise A3::Domain::ConfigurationError, "kanban command argv must not be empty" if @command_argv.empty?

        @working_dir = working_dir && File.expand_path(working_dir)
      end

      def run_json_command(*args)
        stdout, stderr, status = Open3.capture3(*@command_argv, *args, chdir: @working_dir)
        raise A3::Domain::ConfigurationError, build_command_error(stderr, status.exitstatus) unless status.success?

        JSON.parse(stdout)
      rescue JSON::ParserError => e
        raise A3::Domain::ConfigurationError, "kanban command did not return valid JSON: #{args.join(' ')} (#{e.message})"
      end

      def run_command(*args)
        _stdout, stderr, status = Open3.capture3(*@command_argv, *args, chdir: @working_dir)
        raise A3::Domain::ConfigurationError, build_command_error(stderr, status.exitstatus) unless status.success?

        nil
      end

      private

      def tempfile_dir
        @working_dir || Dir.tmpdir
      end

      def build_command_error(stderr, exitstatus)
        detail = stderr.to_s.strip
        message = "kanban command failed (exit=#{exitstatus})"
        detail.empty? ? message : "#{message}: #{detail}"
      end
    end

    KanbanCliCommandClient = SubprocessKanbanCommandClient
  end
end
