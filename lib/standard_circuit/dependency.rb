module StandardCircuit
  # Runtime view of one dependency, returned by `StandardCircuit.dependency`.
  # Cheap to build and holds no state of its own: every reader goes to the
  # live config and runner, so a handle kept across a `configure` or `reset!`
  # still describes the definition it was built from.
  class Dependency
    attr_reader :spec

    def initialize(spec, runner, config)
      @spec = spec
      @runner = runner
      @config = config
    end

    def name
      @spec.name
    end

    # The worst criticality among the purposes.
    def criticality
      @spec.criticality
    end

    def prefix?
      @spec.prefix?
    end

    def purposes
      @spec.purposes.map { |purpose_spec| Purpose.new(self, purpose_spec) }
    end

    # Raises UnknownPurpose for a purpose the dependency does not declare.
    def purpose(name)
      Purpose.new(self, @spec.purpose(name))
    end

    # Names of the circuits (breakers) behind this dependency. For a prefix
    # registration these are the `<prefix>_*` circuits used so far in this
    # process — they can't be enumerated any other way (see Health).
    def circuit_names
      return @spec.circuits.keys unless prefix?

      @runner.cached_lights.keys.select do |circuit|
        !@config.circuits.key?(circuit) && @config.run_target(circuit).dependency == name
      end
    end

    def inspect
      "#<#{self.class.name} #{name.inspect} purposes=#{@spec.purpose_names.inspect}>"
    end

    # One declared reason to call a dependency.
    class Purpose
      attr_reader :dependency, :spec

      def initialize(dependency, spec)
        @dependency = dependency
        @spec = spec
      end

      def name
        @spec.name
      end

      def criticality
        @spec.criticality
      end

      # The circuit guarding calls for this purpose: the dependency's shared
      # breaker, or the purpose's own when isolated. nil for a prefix
      # dependency, whose circuit depends on the name each call uses.
      def circuit_name
        @spec.circuit
      end

      def isolated?
        @spec.isolated?
      end

      def default?
        @spec.default?
      end

      def inspect
        "#<#{self.class.name} #{dependency.name.inspect}/#{name.inspect} criticality=#{criticality.inspect}>"
      end
    end
  end
end
