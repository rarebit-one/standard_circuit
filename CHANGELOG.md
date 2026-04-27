# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- README section on streaming responses and non-controller contexts: shows the recipe for catching `Stoplight::Error::RedLight` inside a `Live` controller's streaming proc (where `circuit_open_fallback` can't render over an open response), and notes the equivalent pattern for background jobs.
- `rails g standard_circuit:install` — Rails install generator. Writes `config/initializers/standard_circuit.rb` with commented-out examples covering the public Config DSL (`register`, `register_prefix`, notifiers, data store, criticality). Idempotent: re-running on an existing initializer skips with a clear message; pass `--force` to overwrite. Pass `--with-health-endpoint` to also write `config/initializers/standard_circuit_health.rb` (which `require`s the opt-in `HealthController`) and print the route line to add to `config/routes.rb`. The generator does not auto-edit `routes.rb` — too invasive — so consumers paste the printed line themselves.
- Rails event emission for every circuit-breaker lifecycle moment. The `StandardCircuit::Runner` (via a small internal `NotifierBridge` registered with Stoplight) now emits five events as host apps' breakers change state:
  - `standard_circuit.circuit.opened` — RED transition (the "alert me" event)
  - `standard_circuit.circuit.closed` — GREEN transition (recovery)
  - `standard_circuit.circuit.degraded` — YELLOW transition (half-open probe)
  - `standard_circuit.circuit.fallback_invoked` — Runner returned a fallback rather than raising RedLight
  - `standard_circuit.circuit.registered` — `Config#register` / `register_prefix` was called
  Payloads carry `circuit:`, `from_color:`, `to_color:`, `criticality:`, and (when applicable) `error_class:` / `error_message:` / `reason:`.
- Dual-backend dispatch in `StandardCircuit::EventEmitter`: emits through `Rails.event.notify` on Rails 8.1+ and falls back to `ActiveSupport::Notifications.instrument` on older Rails. Detection happens at call time, so the gem still loads cleanly before Rails has booted and before `railties` is even required.
- `StandardCircuit::Engine` Railtie that registers the internal subscribers (Logger / Sentry / Metrics) plus any `extra_notifiers` at boot via the `standard_circuit.subscribers` initializer.
- `StandardCircuit.subscribers` accessor + `Subscribers#setup!` / `#teardown!` for tests and host apps that need to re-register listeners after mutating config.

### Changed
- The install template's "Extra notifiers" example now uses `add_notifier` with a 2-arg `call(name, payload)` callable, matching the contract `Config#add_notifier` enforces in 0.2.0+. The previous example wrote directly to `extra_notifiers <<` with a 1-arg lambda — both bypassing validation and using the wrong arity, so any consumer who uncommented it would get `ArgumentError: wrong number of arguments` at boot.
- README "Quick start" and the `rails g standard_circuit:install` initializer template now use `ErrorTaxonomies::*.tracked` consistently (the S3 example in the template still showed the pre-0.1.2 `AdapterErrors::Aws.server_errors` form).
- **BREAKING.** `StandardCircuit::Notifiers::{Logger,Sentry,Metrics}` are no longer Stoplight-shaped notifiers. Each now exposes `call(event_name, payload)` and is registered as an event subscriber by the gem's Railtie. They are still considered an internal implementation detail — host apps that want their own behaviour should subscribe to the `standard_circuit.*` namespace directly rather than instantiating these classes.
- **BREAKING.** `Config#add_notifier` now requires the supplied object to respond to `call(event_name, payload)`. Stoplight-shaped 4-arg notifiers from 0.1.x are rejected with `ArgumentError`. Callers should subscribe via `Rails.event.subscribe` / `ActiveSupport::Notifications.subscribe("standard_circuit.*")` for full control, or pass a lambda to `add_notifier` for the simple case.
- **BREAKING.** Stoplight only sees a single internal `StandardCircuit::NotifierBridge` notifier now; host apps that previously read `StandardCircuit.config.notifiers` to build their own Stoplight light will need to register against the new event namespace instead.
- `lib/standard_circuit/rspec.rb` now also tears down event subscribers between examples so a spec that subscribes manually doesn't leak listeners into the next.

## [0.1.2] - 2026-04-27

### Added
- `StandardCircuit::ErrorTaxonomies::{Stripe,Smtp,Aws,Faraday}.tracked` — pre-combined `NetworkErrors.defaults + AdapterErrors::X.server_errors` arrays. Saves consumers from typing the same line for every circuit they register and gives a single place to evolve what counts as a "server-side outage" per integration. `caller_errors` (validation/auth/etc.) stay on `AdapterErrors::*` because the right `skipped_errors` set is usually app-specific.

### Changed
- `ControllerSupport.circuit_open_fallback` now appends a fresh `rescue_from Stoplight::Error::RedLight` handler each time it's called (deduplicating any prior RedLight handler on the class first, so repeated calls don't accumulate). Rails matches `rescue_handlers` last-declared-first, so a `rescue_from StandardError` catch-all declared *after* `include StandardCircuit::ControllerSupport` previously shadowed the gem's RedLight handler. As long as `circuit_open_fallback` is called after any catch-all rescues in your controller, RedLight now keeps routing to `handle_circuit_open` reliably.

## [0.1.1] - 2026-04-27

### Fixed
- `Mailer::Railtie`'s `standard_circuit.action_mailer` initializer now declares `before: "action_mailer.set_configs"`. Without this hint, the on_load callback that defines `standard_circuit_settings=` ran *after* Rails' `set_configs` initializer tried to forward `config.action_mailer.standard_circuit_settings = {...}` to `ActionMailer::Base`, raising `NoMethodError: undefined method 'standard_circuit_settings='` during eager_load. Two consumers previously worked around this by mutating the Initializer's private `@before` field in their `application.rb`; that workaround can now be removed.

## [0.1.0] - 2026-04-27

### Fixed
- `Mailer::Railtie` is now idempotent: skips `add_delivery_method` when `:standard_circuit` is already in `delivery_methods`. Previously, a host app that pre-registered the delivery method from an env-file `on_load(:action_mailer)` block (a common workaround for the `NoMethodError` that `config.action_mailer.standard_circuit_settings=` triggers during eager_load) would have its settings hash wiped when the gem Railtie's `on_load` fired afterwards, causing `KeyError: key not found: :circuit` at delivery time. Reproduced in production at nutripod-web (Sentry NUTRIPOD-WEB-EE / Linear LMT-454).

### Added
- `StandardCircuit::Mailer::CircuitOpenError` — now the default `retry_error_class` for the mailer delivery method; consumers no longer need to define their own.
- Opt-in `StandardCircuit::HealthController` — `require "standard_circuit/health_controller"` then route `get "/health", to: "standard_circuit/health#show"`. Renders `StandardCircuit.health_report` as JSON and returns 503 on `:critical`.
- Initial extraction from `sidekick-web/app/services/circuit_breaker.rb` (see design doc §4 for the five flaws addressed).
- `StandardCircuit.run(:name, fallback:, &block)` module-method API.
- `StandardCircuit::Config` with `register`, `register_prefix`.
- `StandardCircuit::NetworkErrors` narrow default tracked-errors list.
- `StandardCircuit::AdapterErrors::{Stripe,Aws,Faraday,Smtp}` modules exposing `server_errors` and `caller_errors`.
- `StandardCircuit::Notifiers::{Logger,Sentry,Metrics}`.
- `StandardCircuit::ActiveStorage::S3Service` — per-bucket circuit keying (`:s3_<bucket>`), wraps `upload`/`download`/`download_chunk`/`delete`/`delete_prefixed`/`exist?`/`compose`/`update_metadata`.
- `StandardCircuit::Mailer::DeliveryMethod` — accepts `underlying:` as instance or symbol.
- `StandardCircuit::ControllerSupport` — `circuit_open_fallback` DSL for production 503 handling.
- `StandardCircuit.force_open`, `force_closed`, `reset_force!` + `require "standard_circuit/rspec"` for auto-cleanup.

### Changed
- Minimum Ruby version is now `>= 4.0` (was `>= 3.4`). CI tests all four published 4.0.x patches.
- Removed redundant `defined?(::Sentry::Metrics)` guards in `Runner`, `ControllerSupport`, and `Notifiers::Metrics`. `sentry-ruby` is a hard runtime dependency; the guards were dead code.
- Tightened `sentry-ruby` lower bound from `>= 5.0` to `>= 5.17`. `Sentry::Metrics` was introduced in 5.17; the previous floor let Bundler resolve a version where the metrics API does not exist.

