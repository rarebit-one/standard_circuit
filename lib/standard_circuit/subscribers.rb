module StandardCircuit
  # Registers internal and user-supplied subscribers against whichever event
  # bus is live (Rails.event on 8.1+, ActiveSupport::Notifications elsewhere).
  #
  # Each subscriber must respond to `call(event_name, payload)`. Internal
  # subscribers (Logger / Sentry / Metrics) are built from the live config so
  # changes to `metric_prefix` / `logger` propagate when `setup!` is re-run.
  #
  # Subscriptions cover the namespace prefix `standard_circuit.`, so a single
  # registration on each backend listens for every lifecycle event the gem
  # emits — bridge color transitions plus runner-side fallback / registration.
  #
  # @api private
  class Subscribers
    EVENT_PATTERN = "standard_circuit."

    def initialize
      @rails_event_subscribers = []
      @as_subscribers = []
    end

    def setup!
      teardown!
      register(internal_subscribers + extra_subscribers)
    end

    def teardown!
      @rails_event_subscribers.each do |subscriber|
        next unless EventEmitter.rails_event_available?
        ::Rails.event.unsubscribe(subscriber)
      end
      @rails_event_subscribers.clear

      @as_subscribers.each do |subscriber|
        ::ActiveSupport::Notifications.unsubscribe(subscriber)
      end
      @as_subscribers.clear
    end

    private

    def register(subscribers)
      subscribers.each do |subscriber|
        register_one(subscriber)
      end
    end

    # Register on whichever backend is live. We do not double-subscribe — if
    # `Rails.event` is present, every emit goes through it (see EventEmitter),
    # so the AS::Notifications side would never receive anything.
    def register_one(subscriber)
      if EventEmitter.rails_event_available?
        wrapper = RailsEventAdapter.new(subscriber)
        ::Rails.event.subscribe(wrapper)
        @rails_event_subscribers << wrapper
      else
        regexp = /\A#{Regexp.escape(EVENT_PATTERN)}/
        handle = ::ActiveSupport::Notifications.subscribe(regexp) do |name, _start, _finish, _id, payload|
          subscriber.call(name, payload)
        end
        @as_subscribers << handle
      end
    end

    def internal_subscribers
      config = StandardCircuit.config
      list = [ Notifiers::Logger.new(config.logger) ]
      list << Notifiers::Sentry.new if config.sentry_enabled
      list << Notifiers::Metrics.new(metric_prefix: config.metric_prefix)
      list
    end

    def extra_subscribers
      StandardCircuit.config.extra_notifiers.map do |notifier|
        if notifier.respond_to?(:call)
          notifier
        else
          # Backwards-compat shim: legacy notifiers had a 4-arg `notify`. We
          # cannot reliably reconstruct a stoplight Light, so unwrap to the
          # event-payload form. Such notifiers must migrate to `call`.
          raise ArgumentError,
            "extra notifier #{notifier.inspect} must respond to `call(event_name, payload)`. " \
            "Stoplight-shaped notifiers (notify/4) are no longer supported as extras; subscribe to events directly."
        end
      end
    end

    # Adapts a `call(name, payload)` subscriber to the Rails.event#subscribe
    # contract, which delivers a Hash event with :name / :payload / :context /
    # :tags / :source_location.
    class RailsEventAdapter
      def initialize(subscriber)
        @subscriber = subscriber
      end

      def emit(event)
        name = event[:name]
        return unless name&.start_with?(EVENT_PATTERN)

        @subscriber.call(name, event[:payload] || {})
      end
    end
  end
end
