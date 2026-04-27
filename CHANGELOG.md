# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- `rails g standard_circuit:install` — Rails install generator. Writes `config/initializers/standard_circuit.rb` with commented-out examples covering the public Config DSL (`register`, `register_prefix`, notifiers, data store, criticality). Idempotent: re-running on an existing initializer skips with a clear message; pass `--force` to overwrite. Pass `--with-health-endpoint` to also write `config/initializers/standard_circuit_health.rb` (which `require`s the opt-in `HealthController`) and print the route line to add to `config/routes.rb`. The generator does not auto-edit `routes.rb` — too invasive — so consumers paste the printed line themselves.

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

