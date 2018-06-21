# frozen_string_literal: true

require 'active_support/core_ext/kernel/concern'

concern :Memoizable do
  SUBS = { '?' => '_q', '!' => '_b' }.freeze

  included do
    module Memoization end
    prepend Memoization
  end

  class_methods do
    def memoized(method_name)
      method_name = method_name.to_sym
      variable_name = "@#{method_name}".sub(/[?!]\z/, SUBS).to_sym
      Memoization.module_exec do
        define_method(method_name) do
          if instance_variable_defined?(variable_name)
            instance_variable_get(variable_name)
          else
            instance_variable_set(variable_name, super())
          end
        end
      end
    end
  end
end
