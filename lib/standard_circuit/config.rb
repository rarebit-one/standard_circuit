module StandardCircuit
  class Config
    DEFAULT_THRESHOLD = 3
    DEFAULT_COOL_OFF = 30
    DEFAULT_WINDOW = 60
    DEFAULT_CRITICALITY = :standard
    CRITICALITIES = [ :critical, :standard, :optional ].freeze

    CircuitSpec = Struct.new(
      :threshold,
      :cool_off_time,
      :window_size,
      :tracked_errors,
      :skipped_errors,
      :criticality,
      keyword_init: true
    ) do
      def self.build(**opts)
        criticality = opts.fetch(:criticality, DEFAULT_CRITICALITY)
        unless CRITICALITIES.include?(criticality)
          raise ArgumentError,
            "invalid criticality #{criticality.inspect}; must be one of #{CRITICALITIES.inspect}"
        end

        new(
          threshold: opts.fetch(:threshold, DEFAULT_THRESHOLD),
          cool_off_time: opts.fetch(:cool_off_time, DEFAULT_COOL_OFF),
          window_size: opts.fetch(:window_size, DEFAULT_WINDOW),
          tracked_errors: opts.fetch(:tracked_errors, NetworkErrors.defaults),
          skipped_errors: opts.fetch(:skipped_errors, []),
          criticality: criticality
        )
      end
    end

    attr_accessor :sentry_enabled, :metric_prefix, :data_store, :logger
    attr_reader :circuits, :prefixes, :extra_notifiers, :sentry_criticality_levels

    def initialize
      @sentry_enabled = true
      @sentry_criticality_levels = nil
      @metric_prefix = "external"
      @data_store = Stoplight::DataStore::Memory.new
      @logger = nil
      @circuits = {}
      @prefixes = {}
      @extra_notifiers = []
    end

    # Opt in to criticality-aware Sentry reporting for the built-in Sentry
    # subscriber. Accepts:
    #
    #   nil / false  — (default) flat :warning for every circuit, no tags and
    #                  no fingerprint. The 0.2.x behaviour.
    #   true         — Notifiers::Sentry::DEFAULT_LEVELS
    #                  ({ critical: :error, standard: :warning, optional: :info })
    #   Hash         — DEFAULT_LEVELS merged with the given criticality => level
    #                  pairs, so a partial map is enough.
    #
    # Stored normalized: the reader returns either nil or a frozen, complete
    # criticality => level Hash.
    def sentry_criticality_levels=(value)
      @sentry_criticality_levels = normalize_sentry_criticality_levels(value)
    end

    def reset_registry!
      @circuits.clear
      @prefixes.clear
      @extra_notifiers.clear
    end

    def register(name, **opts)
      spec = CircuitSpec.build(**opts)
      @circuits[name.to_sym] = spec
      EventEmitter.emit("standard_circuit.circuit.registered",
        circuit: name.to_s,
        criticality: spec.criticality,
        scope: :name)
      spec
    end

    def register_prefix(prefix, **opts)
      spec = CircuitSpec.build(**opts)
      @prefixes[prefix.to_s] = spec
      EventEmitter.emit("standard_circuit.circuit.registered",
        circuit: prefix.to_s,
        criticality: spec.criticality,
        scope: :prefix)
      spec
    end

    # Register a host-supplied subscriber. Subscribers must respond to
    # `call(event_name, payload)` — Stoplight-shaped 4-arg notifiers from the
    # 0.1.x API are no longer accepted as extras (Logger / Sentry / Metrics
    # demonstrate the new shape).
    def add_notifier(notifier)
      unless notifier.respond_to?(:call)
        raise ArgumentError,
          "extra notifiers must respond to `call(event_name, payload)`; got #{notifier.class}"
      end
      @extra_notifiers << notifier
    end

    def spec_for(name)
      @circuits[name.to_sym] || spec_for_prefix(name)
    end

    private

    def normalize_sentry_criticality_levels(value)
      case value
      when nil, false then nil
      when true       then Notifiers::Sentry::DEFAULT_LEVELS
      when Hash       then merge_sentry_criticality_levels(value)
      else
        raise ArgumentError,
          "sentry_criticality_levels must be nil, true, false, or a Hash of " \
          "criticality => Sentry level; got #{value.class}"
      end
    end

    def merge_sentry_criticality_levels(map)
      normalized = map.to_h do |criticality, level|
        # Check symbolizability before coercing: a key like 42 would otherwise
        # raise NoMethodError instead of the ArgumentError this setter promises.
        criticality = criticality.to_sym if criticality.respond_to?(:to_sym)
        unless CRITICALITIES.include?(criticality)
          raise ArgumentError,
            "invalid criticality #{criticality.inspect} in sentry_criticality_levels; " \
            "must be one of #{CRITICALITIES.inspect}"
        end
        unless level.respond_to?(:to_sym)
          raise ArgumentError,
            "invalid Sentry level #{level.inspect} for criticality #{criticality.inspect}; " \
            "must be a Symbol or String"
        end
        [ criticality, level.to_sym ]
      end

      Notifiers::Sentry::DEFAULT_LEVELS.merge(normalized).freeze
    end

    def spec_for_prefix(name)
      key = name.to_s
      _matched_prefix, spec = @prefixes.find { |prefix, _| key.start_with?("#{prefix}_") }
      spec
    end
  end
end
