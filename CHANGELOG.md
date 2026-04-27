# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
- Removed redundant `defined?(::Sentry::Metrics)` guards in `Runner`, `ControllerSupport`, and `Notifiers::Metrics`. `sentry-ruby` is a hard runtime dependency; the guards were dead code.
- Tightened `sentry-ruby` lower bound from `>= 5.0` to `>= 5.17`. `Sentry::Metrics` was introduced in 5.17; the previous floor let Bundler resolve a version where the metrics API does not exist.

