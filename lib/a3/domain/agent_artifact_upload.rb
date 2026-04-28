# frozen_string_literal: true

module A3
  module Domain
    class AgentArtifactUpload
      RETENTION_CLASSES = %i[analysis diagnostic evidence temporary].freeze

      attr_reader :artifact_id, :role, :digest, :byte_size, :retention_class, :media_type, :project_key

      def initialize(artifact_id:, role:, digest:, byte_size:, retention_class:, media_type: nil, project_key: A3::Domain::ProjectIdentity.current)
        @project_key = A3::Domain::ProjectIdentity.normalize(project_key)
        @artifact_id = required_string(artifact_id, "artifact_id")
        @role = required_string(role, "role")
        @digest = required_string(digest, "digest")
        @byte_size = Integer(byte_size)
        @retention_class = normalize_retention_class(retention_class)
        @media_type = media_type&.to_s
        freeze
      end

      def self.from_persisted_form(record)
        reject_local_path_reference!(record)
        A3::Domain::ProjectIdentity.require_readable!(project_key: record["project_key"], record_type: "agent artifact upload")
        new(
          artifact_id: record.fetch("artifact_id"),
          project_key: record["project_key"],
          role: record.fetch("role"),
          digest: record.fetch("digest"),
          byte_size: record.fetch("byte_size"),
          retention_class: record.fetch("retention_class"),
          media_type: record["media_type"]
        )
      end

      def persisted_form
        {
          "artifact_id" => artifact_id,
          "project_key" => project_key,
          "role" => role,
          "digest" => digest,
          "byte_size" => byte_size,
          "retention_class" => retention_class.to_s,
          "media_type" => media_type
        }.compact
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.artifact_id == artifact_id &&
          other.project_key == project_key &&
          other.role == role &&
          other.digest == digest &&
          other.byte_size == byte_size &&
          other.retention_class == retention_class &&
          other.media_type == media_type
      end
      alias eql? ==

      def self.reject_local_path_reference!(record)
        path_keys = record.keys.map(&:to_s) & %w[path local_path host_path container_path]
        return if path_keys.empty?

        raise ConfigurationError, "agent artifact uploads must reference A3-managed artifact ids, not local paths: #{path_keys.join(", ")}"
      end

      private_class_method :reject_local_path_reference!

      private

      def required_string(value, name)
        string = value.to_s
        raise ConfigurationError, "#{name} must be provided" if string.empty?

        string
      end

      def normalize_retention_class(value)
        normalized = value.to_sym
        return normalized if RETENTION_CLASSES.include?(normalized)

        raise ConfigurationError, "unsupported agent artifact retention_class: #{value.inspect}"
      end
    end
  end
end
