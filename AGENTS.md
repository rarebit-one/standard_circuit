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
bundle exec brakeman --no-pager
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
│   ├── runner.rb                # Light cache, run/force/reset, metrics
│   ├── health.rb                # Snapshot + overall rollup helpers
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

### Runner

`StandardCircuit::Runner` caches `Stoplight::Light` instances in a `Concurrent::Map`, applies forced-state overrides (`force_open`, `force_closed`), and emits `external.request` count + duration metrics on every call. `reset!` swaps in a fresh `Memory` data store between specs but leaves Redis stores alone. `light_for(name)` builds-on-demand and is used by `Health.snapshot` to materialize named circuits eagerly.

### Health

`Health.snapshot(runner, config)` enumerates every named circuit plus any prefix-matched circuit already cached. `Health.overall(snapshot)` collapses to `:ok | :degraded | :critical` based on criticality + color. `StandardCircuit.health_report` returns both atomically — prefer it over calling `health_snapshot` and `health_overall` separately.

### Notifiers

The default notifier list is `[Logger, Sentry?, Metrics]` plus any registered via `config.add_notifier`. Sentry only fires on transitions to RED; Metrics emits on every transition keyed by `metric_prefix`.

### Adapters

- `ActiveStorage::Service::StandardCircuitS3Service` overrides eight write/read methods with a per-bucket circuit named `:s3_<bucket>`. A shim under `lib/active_storage/service/standard_circuit_s3_service.rb` makes the conventional ActiveStorage `service: StandardCircuitS3` config string resolve.
- `Mailer::DeliveryMethod` accepts either an instance or a `Symbol` for `underlying:` and registers itself via a Railtie as the `:standard_circuit` delivery method. Re-raises `RedLight` as `Mailer::CircuitOpenError` carrying `recipients` + `subject` for the host app's retry layer.

### ControllerSupport

Mix into any controller to turn `Stoplight::Error::RedLight` into a configurable 503. `circuit_open_fallback(html:, json:, stream:, status:)` lets controllers customize the rendered body.

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
| `lib/standard_circuit/config.rb` | `Config` + `CircuitSpec` registry |
| `lib/standard_circuit/runner.rb` | Light cache, forced states, metrics emission |
| `lib/standard_circuit/health.rb` | Snapshot + rollup logic |
| `lib/standard_circuit/controller_support.rb` | RedLight → 503 concern |
| `lib/standard_circuit/network_errors.rb` | Default tracked-error list |
| `spec/spec_helper.rb` | RSpec config + SimpleCov bootstrap |

## Dependencies

- **stoplight** ~> 5.8 (circuit breaker primitives)
- **concurrent-ruby** ~> 1.3 (`Concurrent::Map` for the light cache)
- **sentry-ruby** >= 5.17 (notifier + metrics)
- **railties** >= 8.0 (Railtie hooks for the mailer)

Optional, only loaded when host apps require the relevant adapter:
- **activestorage**, **actionmailer**, **actionpack**
- **aws-sdk-s3**, **stripe**, **faraday**
