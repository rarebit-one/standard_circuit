module StandardCircuit
  # Config-time definition of one external service the app depends on (see
  # `Config#dependency`). A dependency has one or more *purposes*, the declared
  # reasons the app calls it, and each purpose carries a criticality. Purposes
  # share the dependency's breaker unless declared `isolate: true`, which gives
  # the purpose a breaker of its own, named `<dependency>_<purpose>`.
  #
  # A dependency declared without purposes has one implicit purpose,
  # `:default`, with the dependency's criticality. `register` / `register_prefix`
  # produce exactly that shape, so every circuit registered the old way is a
  # dependency too.
  #
  # Immutable once built; `Config` replaces the whole spec on re-registration.
  class DependencySpec
    DEFAULT_PURPOSE = :default
    BREAKER_OPTIONS = [ :threshold, :cool_off_time, :window_size, :tracked_errors, :skipped_errors, :metrics_only ].freeze
    CRITICALITY_RANK = { optional: 0, standard: 1, critical: 2 }.freeze

    PurposeSpec = Data.define(:name, :criticality, :circuit, :isolated, :default) do
      def isolated? = isolated
      def default? = default
    end

    attr_reader :name, :prefix, :purposes, :circuits

    # Build from the `Config#dependency` DSL. +opts+ are the breaker options
    # `register` takes (threshold, cool_off_time, window_size, tracked_errors,
    # skipped_errors, metrics_only); +criticality+ is the default for every
    # purpose.
    def self.define(name, criticality: Config::DEFAULT_CRITICALITY, **opts)
      name = name.to_sym
      validate_criticality!(criticality, "dependency #{name.inspect}")
      validate_breaker_options!(opts, "dependency #{name.inspect}")

      builder = Builder.new(name, criticality)
      yield builder if block_given?
      declared = builder.declared
      declared = [ Builder::Declared.new(DEFAULT_PURPOSE, criticality, false, true, {}) ] if declared.empty?

      shared = declared.reject(&:isolate)
      circuits = {}
      circuits[name] = Config::CircuitSpec.build(**opts, criticality: worst(shared.map(&:criticality))) if shared.any?

      purposes = declared.map do |purpose|
        circuit = purpose.isolate ? :"#{name}_#{purpose.name}" : name
        if purpose.isolate
          circuits[circuit] = Config::CircuitSpec.build(**opts, **purpose.breaker, criticality: purpose.criticality)
        end
        PurposeSpec.new(name: purpose.name, criticality: purpose.criticality, circuit: circuit,
          isolated: purpose.isolate, default: purpose.default)
      end

      new(name: name, purposes: purposes, circuits: circuits)
    end

    # The dependency a plain `register(name, ...)` stands for.
    def self.for_circuit(name, spec)
      name = name.to_sym
      new(name: name, purposes: [ implicit_purpose(spec, name) ], circuits: { name => spec })
    end

    # The dependency a `register_prefix(prefix, ...)` stands for. Its circuits
    # (`<prefix>_<suffix>`) are only known once they have been used.
    def self.for_prefix(prefix, spec)
      new(name: prefix.to_sym, purposes: [ implicit_purpose(spec, nil) ], circuits: {}, prefix: prefix.to_s)
    end

    def self.implicit_purpose(spec, circuit)
      PurposeSpec.new(name: DEFAULT_PURPOSE, criticality: spec.criticality, circuit: circuit, isolated: false, default: true)
    end

    def self.worst(criticalities)
      criticalities.max_by { |criticality| CRITICALITY_RANK.fetch(criticality) }
    end

    def self.validate_criticality!(criticality, owner)
      return if Config::CRITICALITIES.include?(criticality)

      raise ArgumentError,
        "invalid criticality #{criticality.inspect} for #{owner}; must be one of #{Config::CRITICALITIES.inspect}"
    end

    def self.validate_breaker_options!(opts, owner)
      unknown = opts.keys - BREAKER_OPTIONS
      return if unknown.empty?

      raise ArgumentError, "unknown option(s) #{unknown.inspect} for #{owner}; breaker options are #{BREAKER_OPTIONS.inspect}"
    end

    private_class_method :new, :implicit_purpose

    def initialize(name:, purposes:, circuits:, prefix: nil)
      @name = name
      @purposes = purposes.freeze
      @circuits = circuits.freeze
      @prefix = prefix
      freeze
    end

    def prefix?
      !@prefix.nil?
    end

    # The worst criticality among the purposes.
    def criticality
      self.class.worst(@purposes.map(&:criticality))
    end

    def purpose_names
      @purposes.map(&:name)
    end

    def purpose(name)
      key = name.to_sym
      @purposes.find { |purpose| purpose.name == key } or
        raise UnknownPurpose,
          "dependency #{@name.inspect} has no purpose #{key.inspect}; declared: #{purpose_names.inspect}"
    end

    # The purpose a `run` targets. Without +name+ that is the default purpose:
    # the implicit one, or the declared purpose marked `default: true`.
    def resolve_purpose(name)
      return purpose(name) unless name.nil?

      @purposes.find(&:default?) or
        raise PurposeRequired,
          "dependency #{@name.inspect} declares purposes #{purpose_names.inspect}; pass one with `purpose:` " \
          "(or mark one `default: true`)"
    end

    # Collects `purpose` calls inside a `Config#dependency` block.
    class Builder
      Declared = Struct.new(:name, :criticality, :isolate, :default, :breaker)

      attr_reader :declared

      def initialize(dependency, criticality)
        @dependency = dependency
        @criticality = criticality
        @declared = []
      end

      # +isolate: true+ gives the purpose its own breaker, which takes the
      # dependency's breaker options merged with any given here. Breaker
      # options without +isolate+ are rejected: a shared breaker has one set.
      def purpose(name, criticality: @criticality, isolate: false, default: false, **breaker)
        name = name.to_sym
        owner = "purpose #{name.inspect} of dependency #{@dependency.inspect}"
        DependencySpec.validate_criticality!(criticality, owner)
        DependencySpec.validate_breaker_options!(breaker, owner)
        if breaker.any? && !isolate
          raise ArgumentError, "#{owner} sets breaker options #{breaker.keys.inspect} but shares the " \
            "dependency's breaker; pass `isolate: true` to give it its own"
        end
        raise ArgumentError, "#{owner} is declared twice" if @declared.any? { |d| d.name == name }
        if default && @declared.any?(&:default)
          raise ArgumentError, "#{owner} is marked default, but #{@declared.find(&:default).name.inspect} already is"
        end

        @declared << Declared.new(name, criticality, isolate, default, breaker)
        name
      end
    end
  end
end
