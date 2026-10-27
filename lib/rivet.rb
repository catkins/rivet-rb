require "json"
require_relative "rivet/version"
require_relative "rivet/rivet_native"
require_relative "rivet/actor"
require_relative "rivet/context"
require_relative "rivet/registry"
require_relative "rivet/client"

module Rivet
  class Error < StandardError; end
end
