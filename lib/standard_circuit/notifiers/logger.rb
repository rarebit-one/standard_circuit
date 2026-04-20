require "logger"

module StandardCircuit
  module Notifiers
    class Logger
      def initialize(logger = nil)
        @logger = logger || ::Logger.new($stdout)
      end

      def notify(light, from_color, to_color, error)
        message = build_message(light, from_color, to_color, error)
        level = to_color == Stoplight::Color::RED ? :warn : :info
        @logger.public_send(level, message)
        message
      end

      private

      def build_message(light, from_color, to_color, error)
        words = [ "Stoplight", light.name, "switched from", from_color, "to", to_color ]
        words += [ "because", error.class.name, error.message ] if error
        words.join(" ")
      end
    end
  end
end
