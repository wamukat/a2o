# frozen_string_literal: true

module A3
  module Domain
    class ArtifactOwner
      attr_reader :owner_ref, :owner_scope, :snapshot_version

      def initialize(owner_ref:, owner_scope:, snapshot_version:)
        @owner_ref = owner_ref
        @owner_scope = owner_scope.to_sym
        raise ConfigurationError, "snapshot_version must be provided" if snapshot_version.nil?

        @snapshot_version = snapshot_version.to_s
        raise ConfigurationError, "snapshot_version must be provided" if @snapshot_version.empty?
        freeze
      end

      def self.from_persisted_form(record)
        return nil unless record

        new(
          owner_ref: record.fetch("owner_ref"),
          owner_scope: record.fetch("owner_scope"),
          snapshot_version: record.fetch("snapshot_version")
        )
      end

      def persisted_form
        {
          "owner_ref" => owner_ref,
          "owner_scope" => owner_scope.to_s,
          "snapshot_version" => snapshot_version
        }
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.owner_ref == owner_ref &&
          other.owner_scope == owner_scope &&
          other.snapshot_version == snapshot_version
      end
      alias eql? ==
    end
  end
end
