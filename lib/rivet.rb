require "json"

module Rivet
  class Error < StandardError; end
  class TimeoutError < Error; end

  def self.dump(value)
    json = JSON.generate(value)
    pending = [JSON.parse(json)]
    until pending.empty?
      case value = pending.pop
      when Integer
        unless value.between?(-9_223_372_036_854_775_808, 18_446_744_073_709_551_615)
          raise RangeError, "JSON integers must fit in signed or unsigned 64 bits; use a decimal string"
        end
      when Array then pending.concat(value)
      when Hash then pending.concat(value.values)
      end
    end
    json
  end

  def self.timeout_ms(seconds)
    unless seconds.is_a?(Numeric) && seconds.real? && seconds.finite? && seconds > 0
      raise ArgumentError, "timeout must be positive and finite"
    end
    (seconds * 1000).ceil
  end
end

require_relative "rivet/version"
require_relative "rivet/rivet_native"
require_relative "rivet/actor"
require_relative "rivet/context"
require_relative "rivet/registry"
require_relative "rivet/client"
