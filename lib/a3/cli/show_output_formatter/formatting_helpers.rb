# frozen_string_literal: true

module A3
  module CLI
    module ShowOutputFormatter
      module FormattingHelpers
        module_function

        def diagnostic_value(value)
          raw = case value
          when Hash, Array
            value.inspect
          else
            value.to_s
          end
          sanitize_diagnostic_string(raw)
        end

        def sanitize_diagnostic_string(value)
          value
            .gsub("A3_WORKER_REQUEST_PATH", "A2O_WORKER_REQUEST_PATH")
            .gsub("A3_WORKER_RESULT_PATH", "A2O_WORKER_RESULT_PATH")
            .gsub("A3_WORKSPACE_ROOT", "A2O_WORKSPACE_ROOT")
            .gsub("A3_WORKER_LAUNCHER_CONFIG_PATH", "A2O_WORKER_LAUNCHER_CONFIG_PATH")
            .gsub("A3_ROOT_DIR", "A2O_ROOT_DIR")
            .gsub("/tmp/a3-engine/lib/a3", "<runtime-preset-dir>/lib/a2o-internal")
            .gsub("/tmp/a3-engine", "<runtime-preset-dir>")
            .gsub("/usr/local/bin/a3", "<engine-entrypoint>")
            .gsub("lib/a3", "lib/a2o-internal")
            .gsub(".a3", "<agent-metadata>")
        end
      end
    end
  end
end
