# frozen_string_literal: true

module A3
  module Domain
    class WorkerTaskPacket
      attr_reader :ref, :external_task_id, :kind, :edit_scope, :verification_scope,
                  :parent_ref, :child_refs, :title, :description, :status, :labels

      def initialize(ref:, external_task_id:, kind:, edit_scope:, verification_scope:, parent_ref:, child_refs:, title:, description:, status:, labels:)
        @ref = ref.to_s
        @external_task_id = external_task_id && Integer(external_task_id)
        @kind = kind.to_sym
        @edit_scope = Array(edit_scope).map(&:to_sym).freeze
        @verification_scope = Array(verification_scope).map(&:to_sym).freeze
        @parent_ref = parent_ref
        @child_refs = Array(child_refs).map(&:to_s).freeze
        @title = title.to_s
        @description = description.to_s
        @status = status.to_s
        @labels = Array(labels).map(&:to_s).freeze
        freeze
      end

      def request_form
        {
          "ref" => ref,
          "external_task_id" => external_task_id,
          "kind" => kind.to_s,
          "edit_scope" => edit_scope.map(&:to_s),
          "verification_scope" => verification_scope.map(&:to_s),
          "parent_ref" => parent_ref,
          "child_refs" => child_refs,
          "title" => title,
          "description" => description,
          "status" => status,
          "labels" => labels
        }
      end
    end
  end
end
