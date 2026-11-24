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

# with a fallback, returned instead of raising while the circuit is open
StandardCircuit.run(:analytics, fallback: -> { nil }) do
  Analytics.track(event)
end
```

A fallback may take the error (`->(error) { ... }`: the error the block raised,
or `nil` once the circuit is open, since the block then never runs) or take
nothing (`-> { ... }`, or a zero-arity `method(...)`); all are called correctly.

A fallback is used for a **tracked** error the block raised, and instead of
`RedLight` while the circuit is open or forced open. A skipped error, or one
outside `tracked_errors`, is re-raised and the fallback is not called. Either
way the caller gets the fallback's value, but the call is still reported as what
it was: `run.completed`, the `<metric_prefix>.request` metric and the rolling
stats say `:failure` for a failure the fallback absorbed and `:circuit_open`
for an open circuit, and `run.completed` carries `fallback_used: true`. The
absorbed failure counts towards tripping the breaker exactly as a raised one
does.

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

## Dependencies and purposes

A **dependency** is one external service the app calls. A **purpose** is a declared reason the app calls it, and each purpose has its own criticality. One upstream is often called for reasons of different weight: Google OAuth for sign-in (critical) and for Calendar linking (standard). Before purposes, that meant either putting the circuit's criticality on its most important use or hand-splitting circuits.

```ruby
StandardCircuit.configure do |c|
  # One reason to call it: criticality on the dependency, implicit :default purpose.
  c.dependency :stripe, criticality: :critical, threshold: 5, cool_off_time: 30,
               tracked_errors: StandardCircuit::ErrorTaxonomies::Stripe.tracked,
               skipped_errors: StandardCircuit::AdapterErrors::Stripe.caller_errors

  # One upstream, several reasons. The purposes share one breaker.
  c.dependency :google_oauth, threshold: 3, cool_off_time: 30 do |d|
    d.purpose :sign_in,  criticality: :critical
    d.purpose :calendar, criticality: :standard
  end

  # A purpose whose failures look different gets its own breaker.
  c.dependency :google_maps, criticality: :optional do |d|
    d.purpose :places, default: true
    d.purpose :address, isolate: true, threshold: 2   # breaker :google_maps_address
  end
end

StandardCircuit.run(:google_oauth, purpose: :calendar) { calendar.list_events }
StandardCircuit.run(:google_maps) { places.search(query) }   # the default purpose, :places
```

The rules:

- **Breaker options** are the ones `register` takes (`threshold`, `cool_off_time`, `window_size`, `tracked_errors`, `skipped_errors`), passed flat. `criticality:` on the dependency is the default for each purpose.
- **Purposes share the dependency's breaker** by default, because the same upstream's failures are correlated. The shared breaker is named after the dependency and takes the worst criticality among its purposes, which is what `health_report` and the transition events use.
- **`isolate: true`** gives a purpose its own breaker, named `<dependency>_<purpose>`, with the dependency's breaker options plus any passed on the purpose. Breaker options on a purpose that isn't isolated raise `ArgumentError`, because a shared breaker has one set of settings.
- **Purposes are a closed set.** `run` with an undeclared purpose raises `StandardCircuit::UnknownPurpose`. `run` without `purpose:` uses the implicit purpose, or the one declared `default: true`; with neither, it raises `StandardCircuit::PurposeRequired`. Raising beats guessing which purpose a bare call meant, and `default: true` keeps existing bare `run(:name)` call sites working when you add purposes.
- **`register`, `register_prefix` and `register_preset` still work unchanged**, and each now also creates a breaker-only dependency with one implicit `:default` purpose. `StandardCircuit.dependency(:stripe)` finds a circuit registered the old way, and a prefix registration is one dependency whose circuits (`s3_uploads`, `s3_avatars`, ...) are its sub-circuits.
- An isolated purpose's breaker can be run by its own name (`run(:google_maps_address)`), so a hand-split circuit's call sites keep working after you fold it into a purpose. Re-declaring a dependency replaces it; a breaker name another dependency already owns raises `ArgumentError`.

Per-call events (`run.completed`, `fallback_invoked`) carry the **purpose's** criticality, plus `dependency:` and `purpose:` on `run.completed`. For a circuit registered with `register`, that criticality is the circuit's own, exactly as before.

```ruby
dep = StandardCircuit.dependency(:google_maps)   # raises StandardCircuit::UnknownDependency (an UnknownCircuit)
dep.criticality                                  # => :optional (worst purpose)
dep.purposes.map(&:name)                         # => [:places, :address]
dep.purpose(:address).circuit_name               # => :google_maps_address
dep.circuit_names                                # => [:google_maps, :google_maps_address]
StandardCircuit.dependencies                     # every dependency, old-style registrations included
```

Replace your host code with:

```ruby
# Before: criticality pinned to the most important use
c.register(:google_oauth, threshold: 3, criticality: :critical) # "because sign-in depends on it"
StandardCircuit.run(:google_oauth) { calendar.link! }

# After
c.dependency :google_oauth, threshold: 3 do |d|
  d.purpose :sign_in,  criticality: :critical
  d.purpose :calendar, criticality: :standard
end
StandardCircuit.run(:google_oauth, purpose: :calendar) { calendar.link! }
```

```ruby
# Before: a second circuit only because one use fails differently
c.register(:google_maps, criticality: :optional)
c.register(:google_maps_address, threshold: 2, criticality: :optional)

# After: same breaker names, so metrics, health entries and call sites carry over
c.dependency :google_maps, criticality: :optional do |d|
  d.purpose :places, default: true
  d.purpose :address, isolate: true, threshold: 2
end
```

### State and locks

```ruby
dep = StandardCircuit.dependency(:myinfo)
dep.open?          # true while its breaker is open (red, or force_open); half-open (yellow) is not open
dep.status         # :ok | :degraded | :unavailable
dep.circuits       # [{ name: :myinfo, color: "red", locked: false, forced: nil }]
dep.lock_open!     # every call raises RedLight (or returns its fallback) until unlock!
dep.lock_closed!   # every call goes through, failures never trip it
dep.unlock!

dep = StandardCircuit.dependency(:google_maps)
dep.purpose(:address).open?        # an isolated purpose has its own breaker
dep.purpose(:address).status
dep.purpose(:address).lock_open!   # locks only :google_maps_address
```

- `status` takes the worst purpose. Each purpose applies the `health_report` rule to its own criticality and breaker color: critical + red is `:unavailable`; critical + yellow or standard + red is `:degraded`; optional never elevates. A red shared breaker therefore makes `:google_oauth` unavailable through `:sign_in`, even though `:calendar` alone would only be degraded. Error rate and latency don't affect `status`.
- A dependency is `open?` when no purpose can be served, meaning every purpose's breaker is open. For the usual one-breaker dependency that is simply "its breaker is open". `force_open` / `force_closed` count, as they do for `run`. `circuits` shows the light's own `color` and the `forced` override side by side.
- Locking through a purpose that shares the dependency's breaker locks that breaker for every purpose sharing it. A prefix dependency (`register_prefix(:s3)`) locks the `s3_*` sub-circuits used so far in the process, and is `open?` only when all of them are open.
- State is **per process** with the default `Memory` store, like everything else here (see `data_store` below). With a Redis store, locks are shared by every process, which makes `lock_open!` a fleet-wide switch.

Replace your host code with:

```ruby
# Before: reaching into the runner
StandardCircuit.runner.light_for(:stripe).lock(Stoplight::Color::RED)
StandardCircuit.runner.light_for(:stripe).unlock
StandardCircuit.runner.light_for(:myinfo).color == Stoplight::Color::RED

# After
StandardCircuit.dependency(:stripe).lock_open!
StandardCircuit.dependency(:stripe).unlock!
StandardCircuit.dependency(:myinfo).open?
```

### Rolling stats

Every `run` already emits `standard_circuit.run.completed`. A built-in subscriber keeps a rolling window of those calls per dependency and per purpose:

```ruby
StandardCircuit.dependency(:google_oauth).stats
StandardCircuit.dependency(:google_oauth).purpose(:sign_in).stats
# => {
#      calls: 42,                 # calls in the window
#      window_size: 100,
#      counts: { success: 40, failure: 1, circuit_open: 1 },
#      error_rate: 0.0244,        # failure / (success + failure)
#      latency_ms: { p50: 81.2, p95: 240.5 },
#      last_success_at: 2026-11-23 12:00:03 UTC,
#      last_failure_at: 2026-11-23 11:58:41 UTC,
#      consecutive_failures: 0
#    }
```

- **No calls is not healthy.** A dependency or purpose with nothing recorded reports `calls: 0`, `error_rate: nil` and `latency_ms: nil`, so a critical purpose with no evidence can be told apart from one that is working.
- `error_rate` and latency count **attempted** calls only. A `circuit_open` call never reached the upstream, so it is counted but is no evidence either way. A failure that a fallback absorbed counts as a failure here, and a call answered by the fallback while the circuit is open counts as `circuit_open` (see `run.completed` under [Events](#events)).
- The window is the last `stats_window_size` calls (default 100), kept in a fixed ring per dependency and per purpose, so memory stays bounded however much traffic flows. `last_success_at`, `last_failure_at` and `consecutive_failures` outlive the ring.
- **In-process only**: every worker has its own numbers, as with the default `Memory` store. `StandardCircuit.reset!` clears them. Recording never raises into the wrapped call.
- The subscriber is wired with the others, by the engine at boot or by `configure`. A host test suite using `require "standard_circuit/rspec"` tears subscribers down before each example, so call `StandardCircuit.subscribers.setup!` in an example that reads stats.

```ruby
StandardCircuit.configure do |c|
  c.stats_window_size = 200
end
```

### Observing before enforcing (`metrics_only`)

```ruby
c.dependency :new_upstream, criticality: :standard, metrics_only: true
c.dependency :google_maps do |d|
  d.purpose :places, default: true
  d.purpose :address, isolate: true, metrics_only: true   # only this purpose is observed
end
c.register(:legacy_api, metrics_only: true)               # register takes it too
```

A metrics-only breaker times and records every call, and `run.completed` and the request metrics flow exactly as before, but it **never blocks a call by any route**: it doesn't trip, and it ignores `force_open` / `force_closed` and locks. `open?` is always `false`, and its purpose's status is `:ok`. Towards a fallback it behaves like a closed breaker: a tracked error goes to the fallback, anything else is raised. On a purpose it needs `isolate: true`, because a shared breaker either enforces or doesn't. Use it to watch an uncovered dependency's real error rate and latency before choosing a threshold.

### `dependency_report`

```ruby
StandardCircuit.dependency_report
# => [
#      { name: :google_oauth, status: :unavailable, criticality: :critical, open: true, metrics_only: false,
#        stats: { calls: 12, ... },
#        purposes: [
#          { name: :sign_in, criticality: :critical, status: :unavailable, open: true, isolated: false,
#            metrics_only: false, circuits: [:google_oauth], stats: { calls: 0, error_rate: nil, ... } },
#          { name: :calendar, criticality: :standard, status: :degraded, open: true, isolated: false,
#            metrics_only: false, circuits: [:google_oauth], stats: { calls: 12, ... } }
#        ],
#        circuits: [{ name: :google_oauth, color: "red", locked: false, forced: nil }] },
#      ...
#    ]
```

One row per dependency, including every `register` / `register_prefix` circuit. `StandardCircuit.health_report` is unchanged and stays what `standard_health` reads; a later release will contribute `dependency_report` there.

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

StandardCircuit keeps its circuits in its own Stoplight system, named `standard_circuit`, separate from the process-global one a host configures with `Stoplight.configure`. So `Stoplight.light("stripe")` does not find a StandardCircuit circuit, and a host's own `Stoplight.configure` does not change StandardCircuit's store or notifiers. With Redis, keys are namespaced `stoplight:v6:<standard_circuit system id>:...`; stoplight 6 needs Redis 7.4+ (or Valkey 7.2+).

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
| `standard_circuit.circuit.fallback_invoked` | Runner returned a fallback instead of raising RedLight: a forced-open circuit, or a `RedLight` raised inside the block. Not emitted when stoplight hands a failure or an open circuit to the fallback; use `run.completed`'s `fallback_used` for those | `circuit:, reason: (:circuit_open\|:forced_open), criticality:` |
| `standard_circuit.circuit.registered` | `Config#register` / `register_prefix` was called, or once per breaker a `Config#dependency` declares (see note below) | `circuit:, criticality:, scope: (:name\|:prefix)` |
| `standard_circuit.run.completed` | Every wrapped `StandardCircuit.run` call (success, failure, or circuit_open) | `circuit:, status: (:success\|:failure\|:circuit_open), duration_ms:, criticality:, error_class:, error_message:, dependency:, purpose:, fallback_used:` |

> **Note on `standard_circuit.run.completed`:** the per-call event for cost / latency / success-rate dashboards. Fires on every `Runner#execute` invocation and on `force_open` runs; **not** emitted for `force_closed` runs (which intentionally bypass the runner). All payload keys are always present — `error_class` and `error_message` are `nil` on `:success` (and on a `:circuit_open` call answered by a fallback), and `dependency` / `purpose` are `nil` only for a forced name that was never registered. `status` is the call's real outcome even when a fallback answered it: a failure the fallback absorbed is `:failure`, with the absorbed error's `error_class` / `error_message`, and an open or forced-open circuit is `:circuit_open`. `fallback_used` is `true` whenever the caller got the fallback's value, `false` otherwise. `criticality` is the purpose's (see [Dependencies and purposes](#dependencies-and-purposes)). Payload duration uses `duration_ms` (numeric), not `event.duration`, so subscribers work identically on the `Rails.event` and `ActiveSupport::Notifications` backends.

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
- **On exhaustion** it writes one `error` log line, sends a Sentry `:error` event (when `sentry_enabled` and Sentry is initialized, fingerprinted by mailer and action), and emits `standard_circuit.mailer.retries_exhausted`. Every payload holds only `mailer_class`, `mail_action`, `recipient_domains`, `job_id` and `executions`: recipient **domains**, never addresses or subjects. It then **re-raises** the `CircuitOpenError`, so the job fails and lands in your queue backend's failed jobs (Solid Queue's failed executions) where it can be inspected and retried, instead of completing with the email dropped (since 0.4.2). If your Sentry setup also captures job failures (sentry-rails' ActiveJob integration does), that failure arrives as a second event, grouped by the exception rather than by the fingerprint above.
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

### Calling `configure` more than once

`configure` is safe to call repeatedly. Apps register circuits from `to_prepare` because it's the first point where autoloaded error classes are available, and `to_prepare` re-runs on every code reload. Each call re-applies the config and rebuilds the subscribers. `add_notifier` is idempotent: adding "the same" notifier again replaces the earlier entry in place and does not stack a duplicate. Two notifiers are the same when they share an explicit `key:`, or else the same class name (a reloaded class is a new object with the same name), or for lambdas and methods the same source location. The newest instance wins. To register two instances of one class, give them distinct keys:

```ruby
c.add_notifier(WebhookNotifier.new(ops_url), key: :ops)
c.add_notifier(WebhookNotifier.new(audit_url), key: :audit)
```

Replace your host code with:

```ruby
# Before — hand-rolled guard against stacking a notifier on every reload
unless c.extra_notifiers.any? { |n| n.class.name == "CircuitAuditNotifier" }
  c.add_notifier(CircuitAuditNotifier.new)
end

# After
c.add_notifier(CircuitAuditNotifier.new)
```

Circuit registrations (`register` / `register_prefix` / `register_preset`) were already idempotent: the same name overwrites.

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

The old `require` was deprecated in 0.4 and **removed in 0.5**: it now raises `LoadError`, so delete it.

The controller inherits from `ActionController::API` to sidestep app-level filters (authentication, bootstrap redirects, etc.) so probes can call it anonymously.

**If your app also mounts `StandardHealth::Engine` at `/health`, draw the aggregate route first:**

```ruby
get "/health", to: "standard_circuit/health#show"        # aggregate — FIRST
mount StandardHealth::Engine => "/health", as: :standard_health
```

`StandardHealth::Engine` registers sub-paths only (`/alive`, `/ready`, `/diagnostics/env`) — it never serves the aggregate tier itself. An app that mounts the engine and assumes `/health` is covered silently has no aggregate tier at all, with no boot error and no failing route spec to reveal it. The ordering is load-bearing; draw the aggregate route explicitly, first.

## Test API

These are supported public API for host test suites, not internals:

| Method | What it does |
|--------|--------------|
| `StandardCircuit.force_open(name) { ... }` | Treat `name` as open for the block (or until `reset_force!` without a block): `run` raises `Stoplight::Error::RedLight`, or returns the fallback. Emits the same `run.completed` / `fallback_invoked` events as a real open circuit. |
| `StandardCircuit.force_closed(name) { ... }` | Bypass the circuit for the block — `run` just yields. No events. |
| `StandardCircuit.reset_force!` | Clear every forced state. |
| `StandardCircuit.dependency(name).lock_open!` / `lock_closed!` / `unlock!` | Lock every breaker behind a dependency (or `.purpose(p).lock_open!` for one purpose's breaker) in the data store. Unlike `force_open`, the circuit really is locked red, so `health_report` shows it `locked: true`. `reset!` clears it with the `Memory` store. |
| `StandardCircuit.reset!` | Clear the light cache and forced states, and swap in a fresh `Memory` data store (left alone when the store is Redis). |
| `require "standard_circuit/rspec"` | Adds a `before(:each)` that runs `reset!` and tears down subscribers. Circuit registrations are kept. |

All of these are **process-local**. They are test and console tools, not an operational kill switch (see `data_store` above).

## Removed in 0.5

0.4 deprecated these and 0.5 removes them. None of the five consumer apps used any of them at removal time.

| Removed | Use instead |
|---------|-------------|
| `require "standard_circuit/health_controller"` (now `LoadError`) | nothing — the controller is autoloaded; keep the route |
| `StandardCircuit.health_snapshot` | `StandardCircuit.health_report[:circuits]` |
| `StandardCircuit.health_overall` (and `StandardCircuit.runner.health_overall`) | `StandardCircuit.health_report[:status]` |
| `StandardCircuit::AdapterErrors::Faraday.caller_errors` | drop it — `Faraday::ClientError` is never tracked, so skipping it was a no-op |
| `StandardCircuit::ActiveStorage::S3Service` | `ActiveStorage::Service::StandardCircuitS3Service` / `service: StandardCircuitS3` |

Future deprecations warn through `Rails.application.deprecators[:standard_circuit]`, so your app's `config.active_support.deprecation` setting applies.

## License

MIT
