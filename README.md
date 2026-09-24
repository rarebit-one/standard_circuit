# StandardCircuit

Circuit breaker primitives for Rails apps, built on [stoplight](https://github.com/bolshakov/stoplight).

Wraps the upstream `stoplight` gem with:

- Opinionated default error taxonomy (network errors track; caller/config errors do not)
- SDK-specific adapter error bundles (Stripe, AWS, Faraday, SMTP, Postmark) and circuit presets (`:postmark`, `:s3`)
- Rails event emission (`standard_circuit.circuit.{opened,closed,degraded,fallback_invoked,registered}`) with built-in Logger, Sentry, and Sentry::Metrics subscribers
- ActiveStorage S3 adapter with per-bucket circuit keying
- Generic ActionMailer delivery-method wrapper (supports both instance and symbol `underlying:` forms) with opt-in `mailer_retry` for `deliver_later` jobs
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

Pass `--with-health-endpoint` to also print the route line for the health
endpoint, for you to add to `config/routes.rb`.

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

## Error taxonomies

`tracked_errors` decide what counts toward tripping a circuit; `skipped_errors` are re-raised without counting (and win over `tracked_errors` when a class matches both). `StandardCircuit::ErrorTaxonomies::<Adapter>.tracked` combines `NetworkErrors.defaults` with the adapter's server-side errors for `Stripe`, `Smtp`, `Aws`, `Faraday`, and `Postmark`; `StandardCircuit::AdapterErrors::<Adapter>.caller_errors` lists the adapter's caller-side (4xx-style) errors.

When `skipped_errors:` is omitted it defaults to `[]` — except when the tracked list covers the AWS or Postmark caller errors. (Postmark's `ApiInputError` and `InvalidApiKeyError` subclass `Postmark::HttpServerError`, so a circuit tracking `ErrorTaxonomies::Postmark.tracked` without `skipped_errors:` defaults to skipping them.) AWS 5xx responses are dynamically generated `Aws::Errors::ServiceError` subclasses, so `ErrorTaxonomies::Aws.tracked` has to track `ServiceError` itself, which is also the superclass of `Aws::S3::Errors::AccessDenied` and `NoSuchKey`. So for such circuits `skipped_errors` defaults to `AdapterErrors::Aws.caller_errors` (via `ErrorTaxonomies.default_skipped_for`), and a burst of missing-key lookups or permission errors no longer trips the S3 breaker:

```ruby
StandardCircuit.configure do |c|
  # skipped_errors defaults to [Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::AccessDenied]
  c.register_prefix(:s3, tracked_errors: StandardCircuit::ErrorTaxonomies::Aws.tracked)

  # An explicit skipped_errors — even [] — always wins over the default.
  # c.register(:s3_strict, tracked_errors: StandardCircuit::ErrorTaxonomies::Aws.tracked, skipped_errors: [])
end
```

## Presets

Some integrations were registered identically, line for line, in several apps. `c.register_preset` registers them with the shared settings; any `register` option you pass alongside wins, and `name:` renames the circuit.

| Preset | Registers | Settings |
|--------|-----------|----------|
| `:postmark` | `register(:postmark, ...)` | threshold 3, cool-off 60s, `:standard`, `ErrorTaxonomies::Postmark.tracked`, skips `AdapterErrors::Postmark.caller_errors` |
| `:s3` | `register_prefix(:s3, ...)` — matches the `s3_<bucket>` circuits `StandardCircuitS3` opens | threshold 3, cool-off 30s, `:standard`, `ErrorTaxonomies::Aws.tracked`, skips `NoSuchKey` / `AccessDenied` |

Each preset requires its SDK (`postmark`, `aws-sdk-s3`) before building the error lists and raises `ArgumentError` if the gem is missing. That matters for `gem "aws-sdk-s3", require: false`: `ErrorTaxonomies::Aws.tracked` returns only network errors when the SDK hasn't been loaded yet at configure time, which quietly leaves S3 5xx responses untracked.

Replace your host code with:

```ruby
# Before — config/initializers/standard_circuit.rb
c.register(:postmark,
  threshold: 3,
  cool_off_time: 60,
  criticality: :standard,
  tracked_errors: StandardCircuit::NetworkErrors.defaults +
                  [ Postmark::HttpServerError, Postmark::TimeoutError ],
  skipped_errors: [ Postmark::ApiInputError, Postmark::InvalidApiKeyError ])

c.register_prefix(:s3,
  threshold: 3,
  cool_off_time: 30,
  criticality: :standard,
  tracked_errors: StandardCircuit::ErrorTaxonomies::Aws.tracked)

# After
c.register_preset(:postmark)
c.register_preset(:s3)
```

There is deliberately no `:stripe` preset — the apps that wrap Stripe disagree on threshold, criticality, and skips, so `ErrorTaxonomies::Stripe.tracked` stays the shared piece.

## Circuit state storage (`data_store`)

Circuit state (failure counts, colors, locks) lives in a Stoplight data store. StandardCircuit defaults to `Stoplight::DataStore::Memory.new`, which is **per-process**: each Puma worker, Sidekiq/SolidQueue worker, and console gets its own independent view of every circuit.

That is the deliberate default for a Redis-free deployment, and it is usually the right one — a circuit exists to stop *this* process from hammering a dead upstream, and per-process thresholds mean one unlucky worker can't trip the breaker for everyone. But be explicit about what it implies:

- Thresholds are counted per process, so an app with 4 web workers tolerates roughly 4× the configured `threshold` in aggregate before every worker has tripped.
- `/health` reports the circuit colors of **the process that served the request**, so two consecutive probes can legitimately disagree while a circuit is tripping.
- `force_open` / `force_closed` and `reset!` affect only the calling process — they are test and console tools, not an operational kill switch.

Point `data_store` at a shared store if you want cross-process state instead:

```ruby
StandardCircuit.configure do |c|
  # Default — per-process, no external dependency.
  c.data_store = Stoplight::DataStore::Memory.new

  # Shared across processes and hosts (requires the redis gem + a Redis server).
  # c.data_store = Stoplight::DataStore::Redis.new(Redis.new(url: ENV["REDIS_URL"]))
end
```

## Sentry reporting

The built-in Sentry subscriber is on by default (`c.sentry_enabled = true`) and reports every circuit-open transition at a flat `:warning`, with the circuit name, colors, and error in `extra`.

Set `sentry_criticality_levels` to derive the level from the circuit's registered `criticality` instead. That also adds `circuit` / `circuit_criticality` tags and a stable `["circuit-open", <circuit>]` fingerprint, so Sentry alert rules can route on criticality (e.g. page on `circuit_criticality:critical`) and group per circuit:

```ruby
StandardCircuit.configure do |c|
  # { critical: :error, standard: :warning, optional: :info }
  c.sentry_criticality_levels = true

  # Or override part of that map — unlisted criticalities keep the default.
  # c.sentry_criticality_levels = { optional: :debug }
end
```

This is **opt-in, not the default**. Both the level and the fingerprint feed Sentry's alerting and issue grouping, so turning it on for existing apps at gem-upgrade time would silently change what pages and re-group open issues. Leaving `sentry_criticality_levels` unset keeps the flat `:warning` shape byte-for-byte.

If you want something else entirely, set `c.sentry_enabled = false` and subscribe to `standard_circuit.circuit.opened` yourself — the payload carries `criticality`.

## Events

Every circuit lifecycle moment is emitted as a Rails event. On Rails 8.1+ the canonical bus is `Rails.event`; on older Rails versions the gem transparently falls back to `ActiveSupport::Notifications`. Detection happens per-emit, so subscribers do not need to care which backend is live.

| Event | When it fires | Payload |
|-------|---------------|---------|
| `standard_circuit.circuit.opened` | RED transition (circuit tripped) | `circuit:, from_color:, to_color:, criticality:, error_class:, error_message:` |
| `standard_circuit.circuit.closed` | GREEN transition (recovered) | `circuit:, from_color:, to_color:, criticality:` |
| `standard_circuit.circuit.degraded` | YELLOW transition (half-open probe) | `circuit:, from_color:, to_color:, criticality:` |
| `standard_circuit.circuit.fallback_invoked` | Runner returned a fallback instead of raising RedLight | `circuit:, reason: (:circuit_open\|:forced_open), criticality:` |
| `standard_circuit.circuit.registered` | `Config#register` / `register_prefix` was called (see note below) | `circuit:, criticality:, scope: (:name\|:prefix)` |
| `standard_circuit.run.completed` | Every wrapped `StandardCircuit.run` call (success, failure, or circuit_open) | `circuit:, status: (:success\|:failure\|:circuit_open), duration_ms:, criticality:, error_class:, error_message:` |

> **Note on `standard_circuit.run.completed`:** the per-call event for cost / latency / success-rate dashboards. Fires on every `Runner#execute` invocation and on `force_open` runs; **not** emitted for `force_closed` runs (which intentionally bypass the runner). All payload keys are always present — `error_class` and `error_message` are `nil` on `:success`. Payload duration uses `duration_ms` (numeric), not `event.duration`, so subscribers work identically on the `Rails.event` and `ActiveSupport::Notifications` backends.

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

## Mail delivery

The `:standard_circuit` delivery method wraps any registered ActionMailer delivery method in a circuit and raises `StandardCircuit::Mailer::CircuitOpenError` (instead of attempting the send) while that circuit is open:

```ruby
# config/environments/production.rb
config.action_mailer.delivery_method = :standard_circuit
config.action_mailer.standard_circuit_settings = {
  underlying: :postmark,
  underlying_settings: { api_token: ENV.fetch("POSTMARK_API_TOKEN") },
  circuit: :postmark
}
```

### Retrying `deliver_later` while the circuit is open (`mailer_retry`)

Without a retry, a `deliver_later` job that runs during an outage fails once and the email is lost. Opt in and the gem installs `retry_on CircuitOpenError` on `ActionMailer::MailDeliveryJob`:

```ruby
StandardCircuit.configure do |c|
  c.mailer_retry = true                        # wait: 90, attempts: 5, jitter: 0.15
  # c.mailer_retry = { wait: 120, attempts: 8 } # partial overrides; wait: takes anything retry_on does
end
```

- **Off by default.** Nothing is installed unless you set it.
- **Keep `wait` longer than the mail circuit's `cool_off_time`** (the `:postmark` preset uses 60s), or retries land on a circuit that is still open.
- **Reload-safe and idempotent.** Calling `configure` from `to_prepare` on every reload installs the handler once. If a `retry_on CircuitOpenError` is already on the job (for example your old initializer, during migration), the gem leaves it alone. The first install wins, so changing the options later needs a restart.
- **Subclasses inherit it.** A custom `self.delivery_job = MyJob < ActionMailer::MailDeliveryJob` gets the handler, and a `retry_on CircuitOpenError` declared on the subclass takes precedence.
- **On exhaustion** it writes one `error` log line, sends a Sentry `:error` event (when `sentry_enabled` and Sentry is initialized, fingerprinted by mailer and action), and emits `standard_circuit.mailer.retries_exhausted`. Every payload holds only `mailer_class`, `mail_action`, `recipient_domains`, `job_id` and `executions`: recipient **domains**, never addresses or subjects.
- Only `CircuitOpenError` is retried. Errors from the provider while the circuit is closed, such as a SendGrid 429 or a Postmark 422, keep their existing behaviour. Add your own `retry_on` / `discard_on` for those.

Replace your host code with:

```ruby
# Before — config/initializers/mail_delivery_retry.rb (~40–60 lines)
Rails.application.config.to_prepare do
  next if ActionMailer::MailDeliveryJob.rescue_handlers.any? { |h| h.first == StandardCircuit::Mailer::CircuitOpenError.name }

  ActionMailer::MailDeliveryJob.retry_on(StandardCircuit::Mailer::CircuitOpenError,
    wait: 90.seconds, attempts: 5, jitter: 0.15) do |job, error|
    # ...recipient-domain extraction, Rails.logger.error, Sentry.capture_message...
  end
end

# After — inside your existing StandardCircuit.configure block
c.mailer_retry = true
# or, keeping ENV tunables:
c.mailer_retry = {
  wait: ENV.fetch("SENDGRID_CIRCUIT_RETRY_WAIT", 90).to_i,
  attempts: ENV.fetch("SENDGRID_CIRCUIT_RETRY_ATTEMPTS", 5).to_i
}
```

The Sentry fingerprint changes to `["standard_circuit-mailer-retries-exhausted", mailer, action]`, so the first exhaustion after switching opens a new Sentry issue rather than regrouping into your old one.

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

StandardCircuit ships a controller that renders `StandardCircuit.health_report` as JSON. It returns 503 when the rolled-up status is `:critical` (so orchestrators pull the instance out of rotation) and 200 otherwise.

The controller lives in the engine's `app/controllers`, so it is autoloaded. The route is the only opt-in, and apps that don't draw it never load the controller.

```ruby
# config/routes.rb
Rails.application.routes.draw do
  get "/health", to: "standard_circuit/health#show"
end
```

Replace your host code with:

```ruby
# Before — top of config/routes.rb (or config/initializers/standard_circuit_health.rb)
require "standard_circuit/health_controller"

# After — delete the line (and the initializer, if that's all it contained).
```

The old `require` still works in 0.4 but emits a deprecation through `Rails.application.deprecators[:standard_circuit]`. It will be removed in 0.5.

The controller inherits from `ActionController::API` to sidestep app-level filters (authentication, bootstrap redirects, etc.) so probes can call it anonymously.

**If your app also mounts `StandardHealth::Engine` at `/health`, draw the aggregate route first:**

```ruby
get "/health", to: "standard_circuit/health#show"        # aggregate — FIRST
mount StandardHealth::Engine => "/health", as: :standard_health
```

`StandardHealth::Engine` registers sub-paths only (`/alive`, `/ready`, `/diagnostics/env`) — it never serves the aggregate tier itself. An app that mounts the engine and assumes `/health` is covered silently has no aggregate tier at all, with no boot error and no failing route spec to reveal it. The ordering is load-bearing; draw the aggregate route explicitly, first.

## License

MIT
