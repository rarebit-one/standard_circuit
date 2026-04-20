module StandardCircuit
  module Notifiers
    class Sentry
      def notify(light, from_color, to_color, error)
        return unless to_color == Stoplight::Color::RED
        return unless defined?(::Sentry) && ::Sentry.respond_to?(:capture_message)

        message = "Circuit breaker opened: #{light.name}"
        ::Sentry.capture_message(
          message,
          level: :warning,
          extra: {
            circuit: light.name,
            from_color: from_color,
            to_color: to_color,
            error_class: error&.class&.name,
            error_message: error&.message
          }.compact
        )
        message
      end
    end
  end
end
