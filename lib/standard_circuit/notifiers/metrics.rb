module StandardCircuit
  module Notifiers
    class Metrics
      STATE_FOR_COLOR = {
        Stoplight::Color::RED => "opened",
        Stoplight::Color::GREEN => "closed",
        Stoplight::Color::YELLOW => "half_open"
      }.freeze

      def initialize(metric_prefix: "external")
        @metric_prefix = metric_prefix
      end

      def notify(light, _from_color, to_color, _error)
        return unless defined?(::Sentry::Metrics)

        state = STATE_FOR_COLOR.fetch(to_color, to_color)
        ::Sentry::Metrics.count(
          "#{@metric_prefix}.circuit_breaker",
          value: 1,
          attributes: { service: light.name, state: state }
        )
      end
    end
  end
end
