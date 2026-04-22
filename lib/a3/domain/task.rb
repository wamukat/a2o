# frozen_string_literal: true

module A3
  module Domain
    class InvalidPhaseError < StandardError; end

    class Task
      attr_reader :ref, :kind, :edit_scope, :verification_scope, :status, :current_run_ref, :parent_ref, :child_refs, :blocking_task_refs, :priority, :external_task_id, :verification_source_ref

      def initialize(ref:, kind:, edit_scope:, verification_scope: nil, status: :todo, current_run_ref: nil, parent_ref: nil, child_refs: [], blocking_task_refs: [], priority: 0, external_task_id: nil, verification_source_ref: nil)
        @ref = ref
        @kind = kind.to_sym
        @edit_scope = Array(edit_scope).map(&:to_sym).freeze
        @verification_scope = Array(verification_scope || edit_scope).map(&:to_sym).freeze
        @status = status.to_sym
        @current_run_ref = current_run_ref
        @parent_ref = parent_ref
        @child_refs = Array(child_refs).freeze
        @blocking_task_refs = Array(blocking_task_refs).map(&:to_s).reject(&:empty?).uniq.freeze
        @priority = Integer(priority || 0)
        @external_task_id = external_task_id && Integer(external_task_id)
        @verification_source_ref = normalize_optional_ref(verification_source_ref)
        freeze
      end

      def supports_phase?(phase)
        phase_policy.supports_phase?(phase)
      end

      def next_phase_for(phase)
        phase_policy.next_phase_for(phase)
      end

      def terminal_status_for(phase:, outcome:)
        phase_policy.terminal_status_for(phase: phase, outcome: outcome)
      end

      def start_run(run_ref, phase:)
        self.class.new(
          ref: ref,
          kind: kind,
          edit_scope: edit_scope,
          verification_scope: verification_scope,
          status: phase_policy.status_for_phase(phase),
          current_run_ref: run_ref,
          parent_ref: parent_ref,
          child_refs: child_refs,
          blocking_task_refs: blocking_task_refs,
          priority: priority,
          external_task_id: external_task_id,
          verification_source_ref: verification_source_ref
        )
      end

      def complete_run(next_phase:, terminal_status:, verification_source_ref: nil)
        resolved_status =
          if next_phase
            phase_policy.status_for_phase(next_phase)
          else
            terminal_status.to_sym
          end

        self.class.new(
          ref: ref,
          kind: kind,
          edit_scope: edit_scope,
          verification_scope: verification_scope,
          status: resolved_status,
          current_run_ref: nil,
          parent_ref: parent_ref,
          child_refs: child_refs,
          blocking_task_refs: blocking_task_refs,
          priority: priority,
          external_task_id: external_task_id,
          verification_source_ref: verification_source_ref
        )
      end

      def with_verification_source_ref(source_ref)
        self.class.new(
          ref: ref,
          kind: kind,
          edit_scope: edit_scope,
          verification_scope: verification_scope,
          status: status,
          current_run_ref: current_run_ref,
          parent_ref: parent_ref,
          child_refs: child_refs,
          blocking_task_refs: blocking_task_refs,
          priority: priority,
          external_task_id: external_task_id,
          verification_source_ref: source_ref
        )
      end

      def repo_scope_key
        return :both if edit_scope.size > 1

        edit_scope.fetch(0)
      end

      def runnable_phase
        return nil if current_run_ref

        case status
        when :todo
          kind == :parent ? :review : :implementation
        when :in_progress
          kind == :parent ? nil : :implementation
        when :in_review
          kind == :parent ? :review : nil
        when :verifying
          :verification
        when :merging
          :merge
        else
          nil
        end
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.ref == ref &&
          other.kind == kind &&
          other.edit_scope == edit_scope &&
          other.verification_scope == verification_scope &&
          other.status == status &&
          other.current_run_ref == current_run_ref &&
          other.parent_ref == parent_ref &&
          other.child_refs == child_refs &&
          other.blocking_task_refs == blocking_task_refs &&
          other.priority == priority &&
          other.external_task_id == external_task_id &&
          other.verification_source_ref == verification_source_ref
      end
      alias eql? ==

      private

      def normalize_optional_ref(value)
        normalized = value.to_s.strip
        normalized.empty? ? nil : normalized
      end

      def phase_policy
        PhasePolicy.new(task_kind: kind, current_status: status)
      end
    end
  end
end
