# StandardCircuit

Circuit breaker primitives for Rails apps, built on [stoplight](https://github.com/bolshakov/stoplight).

Wraps the upstream `stoplight` gem with:

- Opinionated default error taxonomy (network errors track; caller/config errors do not)
- SDK-specific adapter error bundles (Stripe, AWS, Faraday, SMTP)
- Rails event emission (`standard_circuit.circuit.{opened,closed,degraded,fallback_invoked,registered}`) with built-in Logger, Sentry, and Sentry::Metrics subscribers
- ActiveStorage S3 adapter with per-bucket circuit keying
- Generic ActionMailer delivery-method wrapper (supports both instance and symbol `underlying:` forms)
- Controller concern for standardized 503 responses on `Stoplight::Error::RedLight`
- Test helpers (`force_open`, `force_closed`, `reset_force!`) with RSpec auto-cleanup

## Installation

```ruby
# Gemfile
gem "standard_circuit", git: "https://github.com/rarebit-one/standard_circuit", ref: "<sha>"
```

Then run the install generator to drop a commented-out initializer into
`config/initializers/standard_circuit.rb`:

```bash
bundle add standard_circuit
rails g standard_circuit:install
```

Pass `--with-health-endpoint` to also generate
`config/initializers/standard_circuit_health.rb` (which requires the opt-in
health controller); the generator prints the matching route line for you to
add to `config/routes.rb`.

The generator is idempotent — re-running skips an existing initializer
unless you pass `--force`.

## Quick start

```ruby
# config/initializers/standard_circuit.rb
StandardCircuit.configure do |c|
  c.sentry_enabled = true
  c.metric_prefix = "external"

  c.register(:stripe,
    threshold: 5,
    cool_off_time: 30,
    tracked_errors: StandardCircuit::ErrorTaxonomies::Stripe.tracked,
    skipped_errors: StandardCircuit::AdapterErrors::Stripe.caller_errors)
end
```

```ruby
# anywhere in app code
StandardCircuit.run(:stripe) do
  Stripe::PaymentIntent.create(amount:, currency:)
end
```

## Events

Every circuit lifecycle moment is emitted as a Rails event. On Rails 8.1+ the canonical bus is `Rails.event`; on older Rails versions the gem transparently falls back to `ActiveSupport::Notifications`. Detection happens per-emit, so subscribers do not need to care which backend is live.

| Event | When it fires | Payload |
|-------|---------------|---------|
| `standard_circuit.circuit.opened` | RED transition (circuit tripped) | `circuit:, from_color:, to_color:, criticality:, error_class:, error_message:` |
| `standard_circuit.circuit.closed` | GREEN transition (recovered) | `circuit:, from_color:, to_color:, criticality:` |
| `standard_circuit.circuit.degraded` | YELLOW transition (half-open probe) | `circuit:, from_color:, to_color:, criticality:` |
| `standard_circuit.circuit.fallback_invoked` | Runner returned a fallback instead of raising RedLight | `circuit:, reason: (:circuit_open\|:forced_open), criticality:` |
| `standard_circuit.circuit.registered` | `Config#register` / `register_prefix` was called (see note below) | `circuit:, criticality:, scope: (:name\|:prefix)` |

> **Note on `standard_circuit.circuit.registered`:** subscribers are wired up *after* the `StandardCircuit.configure` block yields, so any `c.register` calls inside that block fire before any subscriber can hear them. This event is reliable only for post-boot, dynamic `register` / `register_prefix` calls — do not rely on it for a boot-time circuit inventory.

Built-in subscribers (Logger / Sentry / Metrics) are registered automatically by the gem's Railtie. Host apps can subscribe to the namespace however they like:

```ruby
# Rails 8.1+
class MyAuditSubscriber
  def emit(event)
    return unless event[:name].start_with?("standard_circuit.")
    Rails.logger.info("circuit event: #{event[:name]} #{event[:payload].inspect}")
  end
end
Rails.event.subscribe(MyAuditSubscriber.new)

# Older Rails
ActiveSupport::Notifications.subscribe(/\Astandard_circuit\./) do |name, _start, _finish, _id, payload|
  Rails.logger.info("circuit event: #{name} #{payload.inspect}")
end

# Quick host-supplied callable (auto-wired at boot via the Railtie)
StandardCircuit.configure do |c|
  c.add_notifier(->(name, payload) { MyAlerting.notify(name, payload) })
end
```

## Streaming and non-controller contexts

`ControllerSupport.circuit_open_fallback` only works for non-streaming responses — once a `Live` controller has flushed any output, Rails can't render an error template over the wire. For a streaming controller, catch `Stoplight::Error::RedLight` *inside* the streaming proc and write a degraded payload before the stream closes:

```ruby
class Api::MessagesController < ApplicationController
  include ActionController::Live

  def stream
    response.headers["Content-Type"] = "application/x-ndjson"

    StandardCircuit.run(:openai) do
      llm.stream do |chunk|
        response.stream.write({ delta: chunk }.to_json + "\n")
      end
    end
  rescue Stoplight::Error::RedLight
    # Only reachable when the circuit was already open at call time —
    # Stoplight raises RedLight before executing the block, not mid-stream.
    # Errors raised mid-stream propagate as their original class through the
    # `ensure` below; add a broader rescue if you also need to write a
    # terminal NDJSON line for those.
    response.stream.write({ error: "service_unavailable" }.to_json + "\n")
  ensure
    response.stream.close
  end
end
```

Same pattern applies in background jobs (where `circuit_open_fallback` doesn't help): wrap the work in `StandardCircuit.run` and rescue `Stoplight::Error::RedLight` to either `discard_on` (avoid thundering retries) or `retry_on` with backoff (defer until cool-off), depending on whether eventual delivery is required.


## Health endpoint

StandardCircuit ships an opt-in controller that renders `StandardCircuit.health_report` as JSON. It returns 503 when the rolled-up status is `:critical` (so orchestrators pull the instance out of rotation) and 200 otherwise.

It's opt-in — not auto-required — so apps that don't want a health route don't pay for it.

```ruby
# config/routes.rb
require "standard_circuit/health_controller"

Rails.application.routes.draw do
  get "/health", to: "standard_circuit/health#show"
end
```

The controller inherits from `ActionController::API` to sidestep app-level filters (authentication, bootstrap redirects, etc.) so probes can call it anonymously.

See [`standard_circuit-design.md`](../standard_circuit-design.md) for the full design.

## License

MIT
