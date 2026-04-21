module StandardCircuit
  # Health-reporting helpers that inspect the Runner's Stoplight Light cache
  # and the Config's registered circuits / prefixes and return structured
  # snapshots plus an overall health status.
  #
  # Intended for mounting in a Rails HealthController or equivalent:
  #
  #   snapshot = StandardCircuit.health_snapshot
  #   status   = StandardCircuit.health_overall
  #   render json: { status: status, circuits: snapshot },
  #          status: (status == :critical ? 503 : 200)
  #
  module Health
    OVERALL_LEVELS = [ :ok, :degraded, :critical ].freeze

    module_function

    # Build a snapshot of every relevant circuit.
    #
    # Includes: every named circuit registered via +Config#register+ (lights
    # are eagerly built if not yet cached so the snapshot reflects real state
    # instead of "never exercised"); plus every circuit already present in the
    # runner's light cache that was matched via a prefix registration.
    #
    # Prefix-registered circuits that have never been exercised are not
    # enumerable and are therefore omitted.
    def snapshot(runner, config)
      entries = named_entries(runner, config) + prefix_entries(runner, config)
      # Dedupe by name — a named circuit might also match a prefix; the named
      # registration wins and we keep its entry.
      entries.uniq { |entry| entry[:name] }
    end

    # Roll the snapshot up to :ok | :degraded | :critical.
    #
    # - any :critical circuit RED    -> :critical
    # - any :critical circuit YELLOW -> :degraded
    # - any :standard circuit RED    -> :degraded
    # - otherwise                    -> :ok
    #
    # :optional circuits never elevate the overall state.
    def overall(snapshot)
      return :critical if snapshot.any? { |e| e[:criticality] == :critical && e[:color] == "red" }

      degraded = snapshot.any? do |e|
        (e[:criticality] == :critical && e[:color] == "yellow") ||
          (e[:criticality] == :standard && e[:color] == "red")
      end

      degraded ? :degraded : :ok
    end

    # --- internals -------------------------------------------------------

    def named_entries(runner, config)
      config.circuits.map do |name, spec|
        build_entry(runner.light_for(name), spec)
      end
    end
    private_class_method :named_entries

    def prefix_entries(runner, config)
      runner.cached_lights.filter_map do |name, light|
        next if config.circuits.key?(name.to_sym)

        spec = config.spec_for(name)
        next unless spec # defensive: light exists but no matching registration

        build_entry(light, spec)
      end
    end
    private_class_method :prefix_entries

    def build_entry(light, spec)
      color = light.color
      entry = {
        name: light.name.to_sym,
        color: color,
        locked: locked?(light),
        criticality: spec.criticality
      }
      cool_off_until = cool_off_until_for(light, spec)
      entry[:cool_off_until] = cool_off_until if color == "red" && cool_off_until
      entry
    end
    private_class_method :build_entry

    def locked?(light)
      state = safe_state(light)
      state == Stoplight::State::LOCKED_RED || state == Stoplight::State::LOCKED_GREEN
    end
    private_class_method :locked?

    def safe_state(light)
      light.state
    rescue StandardError
      nil
    end
    private_class_method :safe_state

    # Best-effort lookup of when a red circuit will next attempt recovery.
    # Falls back to +nil+ when Stoplight's state-store snapshot is unavailable,
    # which prompts callers to omit the key from the entry.
    def cool_off_until_for(light, _spec)
      return nil unless light.respond_to?(:state_store)

      store = light.state_store
      return nil unless store.respond_to?(:state_snapshot)

      snapshot = store.state_snapshot
      snapshot.respond_to?(:recovery_scheduled_after) ? snapshot.recovery_scheduled_after : nil
    rescue StandardError
      nil
    end
    private_class_method :cool_off_until_for
  end
end
