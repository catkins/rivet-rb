require "json"

# MRI bindings for RivetKit actors and clients (Ruby 4+).
#
# Values cross the native bridge directly: nil, booleans, integers, finite
# floats, UTF-8-compatible strings, symbols (as strings), arrays and hashes
# (with stringified keys). Integers must fit in -2**63..2**64-1; use decimal
# strings for larger values. Unsupported objects raise TypeError; to_json is
# not called. Native failures raise {Error}, operation deadlines raise
# {TimeoutError}, and Ruby conversion errors
# retain their normal classes. A timeout does not prove a remote action did not
# run; actions are not automatically retried.
#
# Use ordinary Ruby threads in the main Ractor only. Ractors and Fiber scheduler
# integration are unsupported. Native waits release the GVL but cannot be
# cancelled reliably with Ruby Timeout or Thread#kill. Initialize clients and
# runners after forking, never inherit an initialized native runtime.
module Rivet
  # A native operation or actor callback failed.
  class Error < StandardError; end
  # A binding deadline expired; remote work or Ruby callbacks may still run.
  class TimeoutError < Error; end

  # Convert a positive finite seconds deadline to rounded-up milliseconds.
  # @api private
  # @param seconds [Numeric] duration in seconds
  # @return [Integer] milliseconds
  # @raise [ArgumentError] duration is not positive, finite and real
  def self.timeout_ms(seconds)
    unless seconds.is_a?(Numeric) && seconds.real? && seconds.finite? && seconds > 0
      raise ArgumentError, "timeout must be positive and finite"
    end
    (seconds * 1000).ceil
  end

  # Native implementation objects; use the Ruby wrappers instead. These
  # declarations document extension-defined constants without loading them.
  # @!parse
  #   # Internal runner bridge.
  #   # @api private
  #   class Rivet::NativeRunner; end
  #   # Internal callback envelope.
  #   # @api private
  #   class Rivet::NativeCallback; end
  #   # Internal actor context.
  #   # @api private
  #   class Rivet::NativeContext; end
  #   # Internal server connection.
  #   # @api private
  #   class Rivet::NativeConnection; end
  #   # Internal client transport.
  #   # @api private
  #   class Rivet::NativeClient; end
  #   # Internal actor handle.
  #   # @api private
  #   class Rivet::NativeHandle; end
  #   # Internal client WebSocket.
  #   # @api private
  #   class Rivet::NativeClientConnection; end
  #   # Internal event receiver.
  #   # @api private
  #   class Rivet::NativeSubscription; end
  #   # Internal SQLite transaction.
  #   # @api private
  #   class Rivet::NativeTransaction; end
end

require_relative "rivet/version"
require_relative "rivet/rivet_native"
require_relative "rivet/actor"
require_relative "rivet/context"
require_relative "rivet/registry"
require_relative "rivet/client"
