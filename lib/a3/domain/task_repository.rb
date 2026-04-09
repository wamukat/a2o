# frozen_string_literal: true

module A3
  module Domain
    module TaskRepository
      def save(_task)
        raise NotImplementedError, "#{self.class} must implement #save"
      end

      def fetch(_task_ref)
        raise NotImplementedError, "#{self.class} must implement #fetch"
      end

      def all
        raise NotImplementedError, "#{self.class} must implement #all"
      end

      def delete(_task_ref)
        raise NotImplementedError, "#{self.class} must implement #delete"
      end
    end
  end
end
