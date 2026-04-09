# frozen_string_literal: true

module A3
  module Domain
    class RepositoryError < StandardError; end
    class RecordNotFound < RepositoryError; end
  end
end
