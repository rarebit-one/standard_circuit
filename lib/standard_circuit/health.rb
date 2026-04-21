module StandardCircuit
  # Health-reporting helpers that inspect the Runner's Stoplight Light cache
  # and the Config's registered circuits / prefixes and return structured
  # snapshots plus an overall health status.
  #
  # Intended for mounting in a Rails HealthController. Prefer +health_report+
  # over calling +health_snapshot+ and +health_overall+ separately — the
  # combined call takes a single atomic snapshot, so the rendered status and
  # circuits always describe the same moment:
  #
  #   report = StandardCircuit.health_report
  #   render json: report, status: (report[:status] == :critical ? 503 : 200)
  #
  module Health
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
      {
        name: light.name.to_sym,
        color: light.color,
        locked: locked?(light),
        criticality: spec.criticality
      }
    end
    private_class_method :build_entry

    def locked?(light)
      state = safe_state(light)
      state == Stoplight::State::LOCKED_RED || state == Stoplight::State::LOCKED_GREEN
    end
    private_class_method :locked?

    # Reading +light.state+ can raise when the data store is unreachable
    # (e.g. Redis connection dropped). Swallow the failure so the health
    # endpoint still returns the rest of the snapshot, but log via the
    # configured logger so operators can see the underlying fault.
    def safe_state(light)
      light.state
    rescue StandardError => e
      logger = StandardCircuit.config.logger
      logger&.warn("StandardCircuit::Health.safe_state failed for #{light.name}: #{e.class}: #{e.message}")
      nil
    end
    private_class_method :safe_state
  end
end
