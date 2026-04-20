# StandardCircuit

Circuit breaker primitives for Rails apps, built on [stoplight](https://github.com/bolshakov/stoplight).

Wraps the upstream `stoplight` gem with:

- Opinionated default error taxonomy (network errors track; caller/config errors do not)
- SDK-specific adapter error bundles (Stripe, AWS, Faraday, SMTP)
- Sentry notifier (warning on GREEN→RED) and metrics notifier (`external.circuit_breaker`, `external.request`)
- ActiveStorage S3 adapter with per-bucket circuit keying
- Generic ActionMailer delivery-method wrapper (supports both instance and symbol `underlying:` forms)
- Controller concern for standardized 503 responses on `Stoplight::Error::RedLight`
- Test helpers (`force_open`, `force_closed`, `reset_force!`) with RSpec auto-cleanup

## Installation

```ruby
# Gemfile
gem "standard_circuit", git: "https://github.com/rarebit-one/standard_circuit", ref: "<sha>"
```

## Quick start

```ruby
# config/initializers/standard_circuit.rb
StandardCircuit.configure do |c|
  c.sentry_enabled = true
  c.metric_prefix = "external"

  c.register(:stripe,
    threshold: 5,
    cool_off_time: 30,
    tracked_errors: StandardCircuit::NetworkErrors.defaults + StandardCircuit::AdapterErrors::Stripe.server_errors,
    skipped_errors: StandardCircuit::AdapterErrors::Stripe.caller_errors)
end
```

```ruby
# anywhere in app code
StandardCircuit.run(:stripe) do
  Stripe::PaymentIntent.create(amount:, currency:)
end
```

See [`standard_circuit-design.md`](../standard_circuit-design.md) for the full design.

## License

MIT
