module StandardCircuit
  # Stoplight-shaped notifier whose only job is to translate the upstream
  # `notifier.notify(light, from_color, to_color, error)` callback into a
  # StandardCircuit Rails event.
  #
  # Stoplight calls notifiers on every color transition (GREEN<->RED, RED->YELLOW
  # for half-open recovery). We map each transition to a stable event name and
  # forward a uniform payload to whichever event bus is live.
  #
  # This is the single Stoplight notifier StandardCircuit registers — Logger,
  # Sentry, and Metrics are now subscribers, not direct notifiers.
  #
  # @api private
  class NotifierBridge
    EVENT_FOR_COLOR = {
      Stoplight::Color::RED    => "standard_circuit.circuit.opened",
      Stoplight::Color::GREEN  => "standard_circuit.circuit.closed",
      Stoplight::Color::YELLOW => "standard_circuit.circuit.degraded"
    }.freeze

    def initialize(config)
      @config = config
    end

    def notify(light, from_color, to_color, error)
      event_name = EVENT_FOR_COLOR[to_color]
      return unless event_name

      EventEmitter.emit(event_name, payload_for(light, from_color, to_color, error))
    end

    private

    # Colors go out as Strings ("green"), as they did under stoplight 5;
    # stoplight 6 hands us Symbols. The error is attached only to the
    # GREEN -> RED trip: stoplight 5 never passed one for a failed recovery
    # probe (YELLOW -> RED) and stoplight 6 does, which would add keys to the
    # `circuit.opened` payload.
    def payload_for(light, from_color, to_color, error)
      spec = @config.spec_for(light.name)
      payload = {
        circuit: light.name,
        from_color: from_color.to_s,
        to_color: to_color.to_s,
        criticality: spec&.criticality
      }
      if error && from_color.to_s == Stoplight::Color::GREEN.to_s
        payload[:error_class] = error.class.name
        payload[:error_message] = error.message
      end
      payload
    end
  end
end
