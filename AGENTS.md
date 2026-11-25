# AGENTS.md - AI Agent Guide for StandardCircuit

StandardCircuit is a Ruby gem that wraps the [stoplight](https://github.com/bolshakov/stoplight) circuit breaker library with opinionated defaults for Rails apps: a curated network-error taxonomy, SDK-specific adapter error bundles (Stripe, AWS, Faraday, SMTP), Sentry + metrics notifiers, an ActiveStorage S3 service, an ActionMailer delivery method, and a controller concern that turns `Stoplight::Error::RedLight` into a 503.

## Quick Reference

```bash
# Run tests
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/standard_circuit/runner_spec.rb

# Run linting
bundle exec rubocop

# Auto-fix lint issues
bundle exec rubocop -A

# Security scans (matches CI)
bundle exec brakeman --no-pager --force
bundle exec bundler-audit --update
```

## Project Structure

```
standard_circuit/
├── lib/standard_circuit/
│   ├── version.rb               # Gem version
│   ├── network_errors.rb        # Default network-error taxonomy
│   ├── adapter_errors/          # Per-SDK error bundles
│   │   ├── stripe.rb
│   │   ├── aws.rb
│   │   ├── faraday.rb
│   │   └── smtp.rb
│   ├── notifiers/               # Stoplight notifiers
│   │   ├── logger.rb            # Logs state transitions
│   │   ├── sentry.rb            # Captures GREEN→RED events
│   │   └── metrics.rb           # Sentry::Metrics counters
│   ├── config.rb                # Config + CircuitSpec struct + registry
│   ├── dependency_spec.rb       # DependencySpec / PurposeSpec definitions + DSL builder
│   ├── dependency.rb            # Runtime Dependency / Purpose handles (state, locks, stats, report)
│   ├── stats.rb                 # Rolling per-dependency/per-purpose call stats + subscriber
│   ├── runner.rb                # Light cache, run/force/reset, metrics
│   ├── retry_wait.rb            # Cool-off-floored job retry wait (StandardCircuit.retry_wait)
│   ├── health.rb                # Snapshot + overall rollup helpers (health_report)
│   ├── health_rules.rb          # Opt-in error-rate / slow rules (`health:`)
│   ├── health_row.rb            # Per-dependency row contributed to standard_health
│   ├── health_contribution.rb   # ActiveSupport.on_load(:standard_health) hook
│   ├── health_controller.rb     # Opt-in 503-on-critical health endpoint
│   ├── controller_support.rb    # rescue_from RedLight concern
│   ├── active_storage/
│   │   └── s3_service.rb        # Wraps ActiveStorage S3 ops with circuit
│   ├── mailer/
│   │   ├── delivery_method.rb   # ActionMailer wrapper
│   │   └── circuit_open_error.rb
│   └── rspec.rb                 # Auto-cleanup hook for host apps
└── spec/                        # RSpec tests + dummy support
```

## Key Patterns

### CircuitSpec configuration

`StandardCircuit::Config` exposes `register(name, **opts)` and `register_prefix(prefix, **opts)`. Each call builds an immutable `CircuitSpec` struct (`threshold`, `cool_off_time`, `window_size`, `tracked_errors`, `skipped_errors`, `criticality`). Criticality must be `:critical`, `:standard`, or `:optional` — used by `Health.overall` to roll snapshots up to `:ok | :degraded | :critical`.

```ruby
StandardCircuit.configure do |c|
  c.sentry_enabled = true
  c.metric_prefix  = "external"
  c.register(:stripe,
    threshold: 5,
    tracked_errors: NetworkErrors.defaults + AdapterErrors::Stripe.server_errors,
    skipped_errors: AdapterErrors::Stripe.caller_errors,
    criticality: :critical)
  c.register_prefix("s3", threshold: 10, criticality: :standard)
end
```

### Dependencies and purposes

`Config#dependency(name, criticality:, **breaker_opts) { |d| d.purpose(...) }` builds an immutable `DependencySpec` (see `dependency_spec.rb`). Purposes share the dependency's breaker (circuit named after the dependency, criticality = worst sharing purpose) unless `isolate: true`, which registers `<dependency>_<purpose>`. Every breaker is installed into `Config#circuits`, so `Runner`, `Health`, `NotifierBridge` and `health_report` see dependencies as plain circuits. `register` / `register_prefix` build a one-purpose (`:default`) spec via `DependencySpec.for_circuit` / `for_prefix`. `Config` tracks which dependency owns each named circuit (`@circuit_owners`); re-declaring a dependency drops its stale breakers but overwrites kept ones in place, so `circuits` order (and `health_report` order) never moves.

`Config#run_target(name, purpose)` resolves a `run` to a `RunTarget` (circuit, dependency, purpose, criticality): a named dependency, then an isolated purpose's own circuit name, then a prefix match, else an unregistered name (dependency/purpose nil, so forced states and `UnknownCircuit` behave as before). Forced states and lights stay keyed by circuit. `StandardCircuit.dependency(name)` wraps a spec in a `Dependency` handle that reads live config/runner state: `open?` (every purpose open), `status` (worst purpose, via `Health.severity`, the per-circuit form of `Health.overall`), `circuits` (`Runner#circuit_state`: color, locked, forced) and the lock API (`Runner#lock` / `#unlock` on each breaker).

### Stats and metrics_only

`Stats::Subscriber` is an internal subscriber (wired by `Subscribers#internal_subscribers`) on `standard_circuit.run.completed`. It records into `StandardCircuit.stats`, a `Stats::Store` of fixed-size, mutex-guarded ring `Stats::Window`s keyed by dependency and by `[dependency, purpose]`. `configure` applies `config.stats_window_size` (resizing drops the windows) and `StandardCircuit.reset!` clears them. `CircuitSpec#metrics_only` makes `Runner#run` take `execute_metrics_only`: the light is built (so prefix circuits stay discoverable) but never run through, forced states and locks are ignored, and events, request metrics and fallback semantics match a closed breaker. `StandardCircuit.dependency_report` maps `Dependency#report` over every dependency; `health_report` is untouched.

### Runner

`StandardCircuit::Runner` registers lights in its own stoplight 6 system through the public `Stoplight.register_system` only (no `Stoplight::Wiring::*`; `runner_generations_spec.rb` greps `lib/` to keep it that way), caches them in a `Concurrent::Map`, applies forced-state overrides (`force_open`, `force_closed`), and emits `external.request` count + duration metrics on every call. Every system-level setting is pinned (`SYSTEM_SETTINGS`) because `register_system` otherwise inherits the host's `Stoplight.configure`. Stoplight 6 caches one light per name per system, rejects conflicting re-registration, and never frees a system name, so a rebuild registers the next generation (`standard_circuit`, `standard_circuit_2`, ...; counter per process). The runner rebuilds lazily on the next call after `apply_config!`, `reset!` or a swapped `config.data_store`, and only when needed: a system is reused while every light built in it keeps its registered settings, and a system with no lights built is always reused. Superseded systems stay registered with stoplight. The `standard_circuit/rspec` helper (`RSpecSupport`) is the only file allowed to call stoplight's private `Stoplight.__stoplight__reset!`, guarded by `respond_to?` and arity: it frees superseded systems between examples, then `Runner.restart_generations!` and `runner.drop_system!` bring the runner back to `standard_circuit`. `reset!` swaps in a fresh `Memory` data store between specs but leaves Redis stores alone. `light_for(name)` builds-on-demand and is used by `Health.snapshot` to materialize named circuits eagerly.

Stoplight 6 differences the runner absorbs, so the public behaviour matches the 5.x era: `tracked_errors` / `skipped_errors` are passed on every `light.run` (registration accepts only named classes/modules; per-run lists accept any `===` matcher); `cool_off_time` / `window_size` are rounded up to whole seconds, minimum 1, when the light is built (the `CircuitSpec` keeps the value as given); colors are Symbols upstream and are stringified in `health_report` and event payloads; `NotifierBridge` attaches the error only to GREEN→RED, as stoplight 5 did.

### Health

`Health.snapshot(runner, config)` enumerates every named circuit plus any prefix-matched circuit already cached. `Health.overall(snapshot)` collapses to `:ok | :degraded | :critical` based on criticality + color. `StandardCircuit.health_report` returns both atomically — it is the only public reader (the separate `health_snapshot` / `health_overall` module readers were removed in 0.5).

### Health rows (0.8)

`HealthRow.build(dependency)` turns breaker state, criticality and the opt-in `HealthRules` into one row with four fixed measurements. `health_contribution.rb` hands `StandardCircuit.health_rows` to standard_health >= 0.10 via `contribute_dependencies`, guarded by `respond_to?` so standard_health 0.9 is left alone. Never add a runtime dependency on standard_health; specs use stand-in facades. Keep the measurement keys a fixed set.

### Notifiers

The default notifier list is `[Logger, Sentry?, Metrics]` plus any registered via `config.add_notifier`. Sentry only fires on transitions to RED; Metrics emits on every transition keyed by `metric_prefix`.

### Adapters

- `ActiveStorage::Service::StandardCircuitS3Service` overrides eight write/read methods with a per-bucket circuit named `:s3_<bucket>`. A shim under `lib/active_storage/service/standard_circuit_s3_service.rb` makes the conventional ActiveStorage `service: StandardCircuitS3` config string resolve.
- `Mailer::DeliveryMethod` accepts either an instance or a `Symbol` for `underlying:` and registers itself via a Railtie as the `:standard_circuit` delivery method. Re-raises `RedLight` as `Mailer::CircuitOpenError` carrying `recipients` + `subject` for the host app's retry layer.

### ControllerSupport

Mix into any controller to turn `Stoplight::Error::RedLight` into a configurable 503. `circuit_open_fallback(html:, json:, stream:, status:)` lets controllers customize the rendered body; `json:`/`html:` receive the RedLight when their arity allows; `json:` also answers `ActionController::API` controllers and requests that don't accept HTML (0.8.1). Every circuit-open response gets `Retry-After` (RedLight `retry_after`, else the circuit's `cool_off_time`).

## Configuration

Defaults live in `Config`:
- `threshold: 3`, `cool_off_time: 30`, `window_size: 60`
- `criticality: :standard`
- `tracked_errors: NetworkErrors.defaults` (Net::*, Errno::*, SocketError, OpenSSL::SSL::SSLError)
- `data_store: Stoplight::DataStore::Memory.new` — host apps using Stoplight Redis should swap this in their initializer.

## Testing

- RSpec only; no FactoryBot. Specs live in `spec/standard_circuit/` and `spec/active_storage/`.
- `spec_helper.rb` resets state in `before` (registry + lights + memory data store), and SimpleCov is loaded at the top with branch coverage enabled.
- `lib/standard_circuit/rspec.rb` is a host-app convenience: `require "standard_circuit/rspec"` in a consumer's `rails_helper.rb` to get auto-`reset!` between examples.
- The Gemfile keeps `aws-sdk-s3`, `stripe`, `faraday`, and the `action*` Rails libs in the `:test` group so the gem itself stays Rails-optional in production.

## Key Files

| File | Purpose |
|------|---------|
| `lib/standard_circuit.rb` | Module entry point; require graph + module-level facade |
| `lib/standard_circuit/config.rb` | `Config` + `CircuitSpec` registry, `dependency` DSL, `run_target` resolution |
| `lib/standard_circuit/dependency_spec.rb` | `DependencySpec` / `PurposeSpec` definitions and the purpose builder |
| `lib/standard_circuit/dependency.rb` | `Dependency` / `Purpose` handles: state, locks, stats, report rows |
| `lib/standard_circuit/stats.rb` | Rolling per-dependency / per-purpose call stats and their subscriber |
| `lib/standard_circuit/runner.rb` | Light cache, forced states, metrics emission |
| `lib/standard_circuit/health.rb` | Snapshot + rollup logic |
| `lib/standard_circuit/health_row.rb` | Health row and status table |
| `lib/standard_circuit/health_contribution.rb` | standard_health load hook |
| `lib/standard_circuit/controller_support.rb` | RedLight → 503 concern |
| `lib/standard_circuit/network_errors.rb` | Default tracked-error list |
| `spec/spec_helper.rb` | RSpec config + SimpleCov bootstrap |

## Dependencies

- **stoplight** ~> 6.0, >= 6.0.1 (circuit breaker primitives)
- **concurrent-ruby** ~> 1.3 (`Concurrent::Map` for the light cache)
- **sentry-ruby** >= 5.17 (notifier + metrics)
- **railties** >= 8.1 (Railtie hooks for the mailer)

Optional, only loaded when host apps require the relevant adapter:
- **activestorage**, **actionmailer**, **actionpack**
- **aws-sdk-s3**, **stripe**, **faraday**
