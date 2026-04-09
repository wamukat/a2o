# frozen_string_literal: true

module A3
  module Domain
    class ScopeSnapshot
      attr_reader :edit_scope, :verification_scope, :ownership_scope

      def initialize(edit_scope:, verification_scope:, ownership_scope:)
        @edit_scope = Array(edit_scope).map(&:to_sym).freeze
        @verification_scope = Array(verification_scope).map(&:to_sym).freeze
        @ownership_scope = ownership_scope.to_sym
        freeze
      end

      def self.from_persisted_form(record)
        new(
          edit_scope: record.fetch("edit_scope"),
          verification_scope: record.fetch("verification_scope"),
          ownership_scope: record.fetch("ownership_scope")
        )
      end

      def persisted_form
        {
          "edit_scope" => edit_scope.map(&:to_s),
          "verification_scope" => verification_scope.map(&:to_s),
          "ownership_scope" => ownership_scope.to_s
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.edit_scope == edit_scope &&
          other.verification_scope == verification_scope &&
          other.ownership_scope == ownership_scope
      end
      alias eql? ==
    end
  end
end
