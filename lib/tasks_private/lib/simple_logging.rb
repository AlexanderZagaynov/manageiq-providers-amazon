# frozen_string_literal: true

require 'logger'
require 'active_support/core_ext/module/delegation'

module Kernel
  private
  def logger
    @logger ||= Logger.new(STDOUT)
  end
  delegate *%i(info debug warn error fatal), :to => :logger
end
