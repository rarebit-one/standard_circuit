module StandardCircuit
  class Config
    DEFAULT_THRESHOLD = 3
    DEFAULT_COOL_OFF = 30
    DEFAULT_WINDOW = 60
    DEFAULT_CRITICALITY = :standard
    CRITICALITIES = [ :critical, :standard, :optional ].freeze
    # 90s > the :postmark preset's 60s cool-off, so a retry lands after the
    # breaker has had a chance to half-open. 5 attempts ≈ 7.5 minutes; 15%
    # jitter so a backlog queued during an outage doesn't retry in lockstep.
    MAILER_RETRY_DEFAULTS = { wait: 90, attempts: 5, jitter: 0.15 }.freeze

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

        tracked_errors = opts.fetch(:tracked_errors, NetworkErrors.defaults)

        new(
          threshold: opts.fetch(:threshold, DEFAULT_THRESHOLD),
          cool_off_time: opts.fetch(:cool_off_time, DEFAULT_COOL_OFF),
          window_size: opts.fetch(:window_size, DEFAULT_WINDOW),
          tracked_errors: tracked_errors,
          # An explicit `skipped_errors:` (including `[]`) always wins; the
          # default only kicks in when the key is absent. See
          # ErrorTaxonomies.default_skipped_for for why AWS needs one.
          skipped_errors: opts.fetch(:skipped_errors) { ErrorTaxonomies.default_skipped_for(tracked_errors) },
          criticality: criticality
        )
      end
    end

    attr_accessor :sentry_enabled, :metric_prefix, :data_store, :logger
    attr_reader :circuits, :prefixes, :extra_notifiers, :sentry_criticality_levels, :mailer_retry

    def initialize
      @sentry_enabled = true
      @sentry_criticality_levels = nil
      @metric_prefix = "external"
      @data_store = Stoplight::DataStore::Memory.new
      @logger = nil
      @circuits = {}
      @prefixes = {}
      @extra_notifiers = []
      @mailer_retry = nil
    end

    # Opt in to retrying ActionMailer::MailDeliveryJob on
    # StandardCircuit::Mailer::CircuitOpenError (see Mailer::Retry). Accepts:
    #
    #   nil / false — (default) off; the gem installs nothing.
    #   true        — MAILER_RETRY_DEFAULTS (wait: 90, attempts: 5, jitter: 0.15)
    #   Hash        — MAILER_RETRY_DEFAULTS merged with :wait / :attempts /
    #                 :jitter. `wait:` takes anything `retry_on` does (seconds,
    #                 a Duration, :polynomially_longer, a Proc).
    #
    # The reader returns nil or a frozen, complete Hash.
    def mailer_retry=(value)
      @mailer_retry = normalize_mailer_retry(value)
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

    # Register a circuit from a named preset (see StandardCircuit::Presets):
    #
    #   c.register_preset(:postmark)                  # c.register(:postmark, ...)
    #   c.register_preset(:s3)                        # c.register_prefix(:s3, ...)
    #   c.register_preset(:postmark, name: :mail, threshold: 5)
    #
    # +name:+ overrides the circuit name (or prefix); any other keyword is a
    # `register` option that wins over the preset's value.
    def register_preset(preset, name: preset, **overrides)
      scope, opts = Presets.resolve(preset, **overrides)
      scope == :prefix ? register_prefix(name, **opts) : register(name, **opts)
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

    def normalize_mailer_retry(value)
      case value
      when nil, false then nil
      when true       then MAILER_RETRY_DEFAULTS
      when Hash
        options = value.transform_keys(&:to_sym)
        unknown = options.keys - MAILER_RETRY_DEFAULTS.keys
        unless unknown.empty?
          raise ArgumentError,
            "unknown mailer_retry option(s) #{unknown.inspect}; allowed: #{MAILER_RETRY_DEFAULTS.keys.inspect}"
        end
        MAILER_RETRY_DEFAULTS.merge(options).freeze
      else
        raise ArgumentError, "mailer_retry must be nil, true, false, or a Hash; got #{value.class}"
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
