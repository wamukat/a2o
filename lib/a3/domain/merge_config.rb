# frozen_string_literal: true

module A3
  module Domain
    class MergeConfig
      ALLOWED_TARGETS = %i[merge_to_live merge_to_parent].freeze
      ALLOWED_POLICIES = %i[ff_only ff_or_merge no_ff].freeze

      attr_reader :target, :policy, :target_ref

      def initialize(target:, policy:, target_ref: nil)
        @target = target.to_sym
        @policy = policy.to_sym
        @target_ref = normalize_target_ref(target_ref)
        raise ConfigurationError, "Unknown merge target: #{@target}" unless ALLOWED_TARGETS.include?(@target)
        raise ConfigurationError, "Unknown merge policy: #{@policy}" unless ALLOWED_POLICIES.include?(@policy)

        freeze
      end

      def ==(other)
        other.is_a?(self.class) &&
          other.target == target &&
          other.policy == policy &&
          other.target_ref == target_ref
      end
      alias eql? ==

      private

      def normalize_target_ref(target_ref)
        ref = String(target_ref).strip
        ref.empty? ? nil : ref
      end
    end
  end
end
