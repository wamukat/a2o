# frozen_string_literal: true

module A3
  module Application
    class ExecutionProcessProbe
      DEFAULT_PROCESS_LIST_COMMAND = ["ps", "-ax", "-o", "pid=", "-o", "command="].freeze

      def initialize(storage_dir:, process_list_command: DEFAULT_PROCESS_LIST_COMMAND)
        @storage_dir = File.expand_path(storage_dir)
        @process_list_command = process_list_command
      end

      def active_execute_until_idle?
        process_lines.any? { |line| execute_until_idle_process?(line) }
      end

      private

      def process_lines
        IO.popen(@process_list_command, &:read).each_line(chomp: true)
      rescue SystemCallError
        []
      end

      def execute_until_idle_process?(line)
        line.include?(" execute-until-idle ") && line.include?(@storage_dir)
      end
    end
  end
end
