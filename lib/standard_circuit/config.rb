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
      :metrics_only,
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
          criticality: criticality,
          # Time and record calls, but never open: see Runner#execute_metrics_only.
          metrics_only: opts.fetch(:metrics_only, false) ? true : false
        )
      end
    end

    # What a `run` resolves to: the circuit (breaker) that guards the call,
    # plus the dependency and purpose it is made for. +dependency+ and
    # +purpose+ are nil for a name nothing was registered under; the runner
    # then raises UnknownCircuit exactly as before (forced states aside).
    RunTarget = Data.define(:circuit, :dependency, :purpose, :criticality)

    attr_accessor :sentry_enabled, :metric_prefix, :data_store, :logger
    attr_reader :circuits, :prefixes, :extra_notifiers, :sentry_criticality_levels, :mailer_retry,
      :stats_window_size

    def initialize
      @sentry_enabled = true
      @sentry_criticality_levels = nil
      @metric_prefix = "external"
      @data_store = Stoplight::DataStore::Memory.new
      @logger = nil
      @circuits = {}
      @prefixes = {}
      @dependencies = {}
      @prefix_dependencies = {}
      @circuit_owners = {}
      @extra_notifiers = []
      @extra_notifier_keys = []
      @mailer_retry = nil
      @stats_window_size = Stats::DEFAULT_WINDOW_SIZE
    end

    # How many recent calls each dependency's and purpose's rolling stats
    # keep (see Stats). Applied on `configure`; changing it drops the windows.
    def stats_window_size=(size)
      unless size.is_a?(Integer) && size.positive?
        raise ArgumentError, "stats_window_size must be a positive Integer; got #{size.inspect}"
      end

      @stats_window_size = size
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
      @dependencies.clear
      @prefix_dependencies.clear
      @circuit_owners.clear
      @extra_notifiers.clear
      @extra_notifier_keys.clear
    end

    # Registers circuit +name+, and with it a breaker-only dependency of the
    # same name with one implicit purpose (see DependencySpec). +health:+
    # takes the opt-in health-row rules (see HealthRules).
    def register(name, health: nil, **opts)
      spec = CircuitSpec.build(**opts)
      install_dependency(DependencySpec.for_circuit(name, spec, health: health))
      EventEmitter.emit("standard_circuit.circuit.registered",
        circuit: name.to_s,
        criticality: spec.criticality,
        scope: :name)
      spec
    end

    # Registers every circuit named `<prefix>_<anything>`. They are the
    # sub-circuits of one dependency named +prefix+.
    def register_prefix(prefix, health: nil, **opts)
      spec = CircuitSpec.build(**opts)
      dependency = DependencySpec.for_prefix(prefix, spec, health: health)
      @prefixes[prefix.to_s] = spec
      @prefix_dependencies[prefix.to_sym] = dependency
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

    # Declare an external service the app depends on, with the reasons
    # (purposes) it calls it:
    #
    #   c.dependency :stripe, criticality: :critical, threshold: 5,
    #                tracked_errors: ErrorTaxonomies::Stripe.tracked
    #
    #   c.dependency :google_oauth, threshold: 3 do |d|
    #     d.purpose :sign_in,  criticality: :critical
    #     d.purpose :calendar, criticality: :standard
    #   end
    #
    #   c.dependency :google_maps, criticality: :optional do |d|
    #     d.purpose :places, default: true
    #     d.purpose :address, isolate: true, threshold: 2   # breaker :google_maps_address
    #   end
    #
    # Breaker options are the ones `register` takes. +criticality:+ is the
    # default for each purpose. +health:+ takes the opt-in health-row rules
    # (`error_rate:`, `slow_ms:`, `min_calls:`; see HealthRules), off by default. See DependencySpec for the rules. Re-declaring
    # a dependency replaces it; a breaker name already owned by another
    # dependency raises ArgumentError.
    def dependency(name, **opts, &block)
      spec = DependencySpec.define(name, **opts, &block)
      install_dependency(spec)
      spec.circuits.each do |circuit, circuit_spec|
        EventEmitter.emit("standard_circuit.circuit.registered",
          circuit: circuit.to_s,
          criticality: circuit_spec.criticality,
          scope: :name)
      end
      spec
    end

    # Every dependency, named ones first, then one per prefix registration.
    def dependency_specs
      @dependencies.values + @prefix_dependencies.values
    end

    # A named dependency wins over a prefix dependency of the same name.
    def dependency_spec(name)
      key = name.to_sym
      @dependencies[key] || @prefix_dependencies[key] or
        raise UnknownDependency, "no dependency registered for #{key.inspect}"
    end

    # Resolve what `run(name, purpose:)` guards. +name+ is a dependency, or a
    # circuit: a prefix-matched one (`:s3_uploads`) or an isolated purpose's
    # own breaker (`:google_maps_address`).
    def run_target(name, purpose = nil)
      key = name.to_sym
      if (dependency = @dependencies[key])
        target_for(dependency, dependency.resolve_purpose(purpose))
      elsif (owner = @circuit_owners[key])
        dependency = @dependencies.fetch(owner)
        resolved = dependency.purposes.find { |p| p.circuit == key }
        check_purpose!(dependency, resolved, purpose)
        target_for(dependency, resolved)
      elsif (dependency = prefix_dependency_for(key))
        resolved = dependency.resolve_purpose(purpose)
        RunTarget.new(circuit: key, dependency: dependency.name, purpose: resolved.name, criticality: resolved.criticality)
      else
        raise UnknownCircuit, "no circuit registered for #{key.inspect}" unless purpose.nil?

        RunTarget.new(circuit: key, dependency: nil, purpose: nil, criticality: spec_for(key)&.criticality)
      end
    end

    # Register a host-supplied subscriber. Subscribers must respond to
    # `call(event_name, payload)` — Stoplight-shaped 4-arg notifiers from the
    # 0.1.x API are no longer accepted as extras (Logger / Sentry / Metrics
    # demonstrate the new shape).
    #
    # Idempotent: hosts call `configure` from `to_prepare`, which re-runs on
    # every code reload, so re-adding "the same" notifier replaces the earlier
    # entry in place instead of stacking a duplicate. "The same" means the same
    # +key:+ when one is given, otherwise:
    #
    #   * a Proc / Method — same source location (a lambda re-created on reload)
    #   * a Class / Module used directly — same name
    #   * any other object — same class name (a reloaded class is a new class
    #     object with the same name, so compare names, not classes)
    #   * an instance of an anonymous class — never deduped
    #
    # The newest instance wins, so a reloaded notifier class takes effect.
    # Pass distinct +key:+ values to register two instances of one class
    # (e.g. two webhook notifiers pointed at different URLs).
    def add_notifier(notifier, key: nil)
      unless notifier.respond_to?(:call)
        raise ArgumentError,
          "extra notifiers must respond to `call(event_name, payload)`; got #{notifier.class}"
      end

      identity = key.nil? ? notifier_identity(notifier) : [ :key, key ]
      index = identity && @extra_notifier_keys.index(identity)
      if index
        @extra_notifiers[index] = notifier
      else
        @extra_notifiers << notifier
        @extra_notifier_keys << identity
      end
      notifier
    end

    def spec_for(name)
      @circuits[name.to_sym] || spec_for_prefix(name)
    end

    private

    # Swap in +spec+ for the dependency of the same name: drop the breakers the
    # previous definition registered, then register the new ones. Breakers
    # the new definition keeps are overwritten in place rather than deleted
    # and re-added, so `circuits` (and so `health_report`) keeps its order.
    # Every conflict is checked before anything changes, so a rejected
    # definition leaves the registry exactly as it was.
    def install_dependency(spec)
      check_names!(spec)

      stale = @circuit_owners.select { |circuit, owner| owner == spec.name && !spec.circuits.key?(circuit) }
      stale.each_key do |circuit|
        @circuits.delete(circuit)
        @circuit_owners.delete(circuit)
      end

      spec.circuits.each do |circuit, circuit_spec|
        @circuits[circuit] = circuit_spec
        @circuit_owners[circuit] = spec.name
      end
      @dependencies[spec.name] = spec
    end

    # `run(name)` resolves a dependency name before a breaker name, so the two
    # share one namespace across dependencies: a breaker may not take another
    # dependency's name or another dependency's breaker, and a dependency may
    # not take another dependency's breaker name.
    def check_names!(spec)
      spec.circuits.each_key do |circuit|
        owner = @circuit_owners[circuit]
        owner = circuit if owner.nil? && @dependencies.key?(circuit)
        next if owner.nil? || owner == spec.name

        raise ArgumentError,
          "circuit #{circuit.inspect} of dependency #{spec.name.inspect} is already registered by dependency #{owner.inspect}"
      end

      owner = @circuit_owners[spec.name]
      return if owner.nil? || owner == spec.name

      raise ArgumentError,
        "dependency #{spec.name.inspect} has the name of a circuit already registered by dependency #{owner.inspect}"
    end

    def target_for(dependency, purpose)
      RunTarget.new(circuit: purpose.circuit, dependency: dependency.name, purpose: purpose.name,
        criticality: purpose.criticality)
    end

    def check_purpose!(dependency, resolved, requested)
      return if requested.nil? || requested.to_sym == resolved.name

      raise UnknownPurpose,
        "circuit #{resolved.circuit.inspect} is the breaker of purpose #{resolved.name.inspect} of dependency " \
        "#{dependency.name.inspect}, not #{requested.inspect}"
    end

    def prefix_dependency_for(name)
      key = name.to_s
      _prefix, dependency = @prefix_dependencies.find { |prefix, _| key.start_with?("#{prefix}_") }
      dependency
    end

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

    def notifier_identity(notifier)
      if notifier.respond_to?(:source_location) && notifier.source_location
        [ :source, notifier.source_location ]
      elsif notifier.is_a?(Module)
        notifier.name && [ :module, notifier.name ]
      else
        notifier.class.name && [ :class, notifier.class.name ]
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
