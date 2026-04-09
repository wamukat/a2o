# frozen_string_literal: true

module A3
  module Domain
    class ConfigurationError < StandardError; end
    class ConfigurationConflictError < ConfigurationError; end
  end
end
