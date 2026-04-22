# frozen_string_literal: true

module A3
  module Infra
    class AgentWorkspaceRepoPolicy
      def initialize(available_slots:, required_slots: nil)
        @available_slots = normalize_slots(available_slots)
        @required_slots = required_slots.nil? ? nil : normalize_slots(required_slots)
      end

      def required_slots
        @required_slots || @available_slots
      end

      def resolve_slots(workspace:)
        materialized_slots = workspace.slot_paths.keys.map(&:to_sym).uniq.sort
        return required_slots if materialized_slots.empty?
        return required_slots if materialized_slots == required_slots

        missing_slots = required_slots - materialized_slots
        extra_slots = materialized_slots - required_slots
        details = []
        details << "missing=#{missing_slots.join(',')}" unless missing_slots.empty?
        details << "extra=#{extra_slots.join(',')}" unless extra_slots.empty?
        raise A3::Domain::ConfigurationError,
          "materialized workspace slots must match the required agent repo set (#{details.join(' ')})"
      end

      private

      def normalize_slots(slots)
        Array(slots).map(&:to_sym).uniq.sort.freeze
      end
    end
  end
end
