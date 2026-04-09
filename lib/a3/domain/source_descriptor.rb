# frozen_string_literal: true

module A3
  module Domain
    class SourceDescriptor
      WORKSPACE_KINDS = %i[ticket_workspace runtime_workspace].freeze
      SOURCE_TYPES = %i[branch_head detached_commit integration_record].freeze

      attr_reader :workspace_kind, :source_type, :ref, :task_ref

      def self.implementation(task_ref:, ref:)
        new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: ref,
          task_ref: task_ref
        )
      end

      def self.runtime(task_ref:, ref:, source_type:)
        new(
          workspace_kind: :runtime_workspace,
          source_type: source_type,
          ref: ref,
          task_ref: task_ref
        )
      end

      def self.for_phase(task:, phase:, ref:)
        case phase.to_sym
        when :implementation
          implementation(task_ref: task.ref, ref: ref)
        when :review, :verification, :merge
          runtime(
            task_ref: task.ref,
            ref: ref,
            source_type: default_runtime_source_type_for(task: task)
          )
        else
          raise InvalidPhaseError, "unsupported phase #{phase}"
        end
      end

      def initialize(workspace_kind:, source_type:, ref:, task_ref:)
        @workspace_kind = normalize_workspace_kind(workspace_kind)
        @source_type = normalize_source_type(source_type)
        @ref = ref
        @task_ref = task_ref
        freeze
      end

      def self.from_persisted_form(record)
        new(
          workspace_kind: record.fetch("workspace_kind"),
          source_type: record.fetch("source_type"),
          ref: record.fetch("ref"),
          task_ref: record.fetch("task_ref")
        )
      end

      def self.ticket_branch_head(task_ref:, ref:)
        new(
          workspace_kind: :ticket_workspace,
          source_type: :branch_head,
          ref: ref,
          task_ref: task_ref
        )
      end

      def self.runtime_detached_commit(task_ref:, ref:)
        new(
          workspace_kind: :runtime_workspace,
          source_type: :detached_commit,
          ref: ref,
          task_ref: task_ref
        )
      end

      def self.runtime_integration_record(task_ref:, ref:)
        new(
          workspace_kind: :runtime_workspace,
          source_type: :integration_record,
          ref: ref,
          task_ref: task_ref
        )
      end

      def self.source_types
        SOURCE_TYPES
      end

      def persisted_form
        {
          "workspace_kind" => workspace_kind.to_s,
          "source_type" => source_type.to_s,
          "ref" => ref,
          "task_ref" => task_ref
        }
      end

      def implementation?
        workspace_kind == :ticket_workspace
      end

      def runtime?
        workspace_kind == :runtime_workspace
      end

      def with_workspace_kind(workspace_kind)
        self.class.new(
          workspace_kind: workspace_kind,
          source_type: source_type,
          ref: ref,
          task_ref: task_ref
        )
      end

      def ticket_workspace?
        workspace_kind == :ticket_workspace
      end

      def runtime_workspace?
        workspace_kind == :runtime_workspace
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.workspace_kind == workspace_kind &&
          other.source_type == source_type &&
          other.ref == ref &&
          other.task_ref == task_ref
      end
      alias eql? ==

      private

      def normalize_workspace_kind(workspace_kind)
        normalized = workspace_kind.to_sym
        return normalized if WORKSPACE_KINDS.include?(normalized)

        raise ConfigurationError, "unsupported workspace_kind: #{workspace_kind.inspect}"
      end

      def normalize_source_type(source_type)
        normalized = source_type.to_sym
        return normalized if SOURCE_TYPES.include?(normalized)

        raise ConfigurationError, "unsupported source_type: #{source_type.inspect}"
      end

      def self.default_runtime_source_type_for(task:)
        task.kind == :parent ? :integration_record : :branch_head
      end
      private_class_method :default_runtime_source_type_for
    end
  end
end
