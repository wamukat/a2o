# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "time"

module A3
  module Infra
    module WorkspaceTraceLogger
      module_function

      def log(workspace_root:, event:, payload: {})
        root = Pathname(workspace_root)
        trace_path = root.join(".a3", "trace.log")
        FileUtils.mkdir_p(trace_path.dirname)
        trace_path.open("a") do |file|
          file.puts(
            JSON.generate(
              "ts" => Time.now.utc.iso8601(6),
              "pid" => Process.pid,
              "event" => event,
              "payload" => payload
            )
          )
        end
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end
    end
  end
end
