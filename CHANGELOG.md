# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.1] - 2026-09-24

### Fixed
- **`mailer_retry` no longer crashes a lazily-loaded process with `NameError: uninitialized constant ActionMailer::MailDeliveryJob`.** 0.4.0 installed the retry from `ActiveSupport.on_load(:active_job)` and referenced `ActionMailer::MailDeliveryJob` inside the hook. When `class MailDeliveryJob < ActiveJob::Base` was itself what loaded `ActiveJob::Base`, the hook ran while that class was still being autoloaded. In development this broke the first `deliver_later` of a fresh process, and `bin/tapioca dsl` hit it too. Eager-loaded production processes and RSpec runs were not affected. The retry is now installed at whichever of these happens first, and never while `MailDeliveryJob` is still mid-autoload:
  - `ActiveJob::Base` loads when `MailDeliveryJob` can already be referenced safely.
  - `ActionMailer::Base` loads. It references `MailDeliveryJob`, so the class is complete by then. Every delivery goes through a mailer, so this also covers a worker that deserializes the job before any mailer loads.
  - Something subclasses `MailDeliveryJob`. This covers a custom `delivery_job` with its own `rescue_from` that loads before any mailer. The subclass's own handlers keep precedence.

  A new integration spec boots a Rails app in a subprocess for each load order (mailer first, job first, subclass first, `ActiveJob::Base` first, eager load).

  **Hosts can delete their workaround.** Any initializer that preloads `ActiveJob::Base` to dodge this bug, such as jumpdrive-web's `config.after_initialize { ActiveJob::Base }`, can be removed.

## [0.4.0] - 2026-09-24

A developer-experience release that moves code copy-pasted across the five consumer apps into the gem. Everything is additive: behaviour is unchanged unless you opt in, and deprecated APIs keep working until 0.5.

### Added
- **`ErrorTaxonomies::Postmark` / `AdapterErrors::Postmark`.** `server_errors` is `[Postmark::HttpServerError, Postmark::TimeoutError]` and `caller_errors` is `[Postmark::ApiInputError, Postmark::InvalidApiKeyError]`. Both return `[]` when the postmark gem isn't loaded. `ErrorTaxonomies.default_skipped_for` now also covers Postmark, because `ApiInputError` and `InvalidApiKeyError` subclass the tracked `HttpServerError`. A circuit that tracks `HttpServerError` and has no `skipped_errors:` now skips them by default, the same way AWS caller errors are skipped since 0.3.1. None of the consumers is affected: all three Postmark circuits pass `skipped_errors:` explicitly.
- **`Config#register_preset(:postmark | :s3, name:, **overrides)`.** It replaces the identical `:postmark` registrations in jumpdrive-web, fundbright-web and luminality-web, and the identical `register_prefix(:s3, ...)` in luminality-web, sidekick-web and nutripod-web. Each preset requires its SDK first (`postmark`, `aws-sdk-s3`) and raises `ArgumentError` if the SDK is missing. This matters when `aws-sdk-s3` is declared `require: false`: in that case `ErrorTaxonomies::Aws.tracked` evaluated at configure time contains only network errors. There is deliberately no `:stripe` preset, because the apps' Stripe registrations differ.
- **Opt-in `config.mailer_retry`** (`true`, or `{ wait:, attempts:, jitter: }` over the defaults `90 / 5 / 0.15`; off by default). It installs `retry_on StandardCircuit::Mailer::CircuitOpenError` on `ActionMailer::MailDeliveryJob`. The install is idempotent and reload-safe, and it stands down if a `CircuitOpenError` handler is already present. On exhaustion it writes an error log line, sends a Sentry `:error` event and emits a new `standard_circuit.mailer.retries_exhausted` event, all carrying recipient domains only. It replaces `config/initializers/mail_delivery_retry.rb` in jumpdrive-web, sidekick-web and nutripod-web (their provider-specific retries and discards stay in the apps), and the `CircuitOpenError` `retry_on` in fundbright-web's `ApplicationMailDeliveryJob`. The Sentry fingerprint is new, so the first exhaustion after switching opens a new issue.
- `StandardCircuit.deprecator`, registered as `Rails.application.deprecators[:standard_circuit]`.
- `Config#add_notifier(notifier, key:)`: an optional `key:` for registering several instances of one notifier class (see Changed).
- README sections: presets, mail delivery and `mailer_retry`, calling `configure` more than once, supported test API (`force_open`, `force_closed`, `reset_force!`, `reset!`, `standard_circuit/rspec`), and deprecations. Each feature has a "replace your host code with" snippet.

### Changed
- **`StandardCircuit::HealthController` is autoloaded by the engine.** It moved to `app/controllers/standard_circuit/health_controller.rb`, so drawing `get "/health", to: "standard_circuit/health#show"` is all a host needs. The boot probe spec now covers autoload, eager load and both legacy `require` placements. The install generator's `--with-health-endpoint` no longer writes `config/initializers/standard_circuit_health.rb`, which only ever contained the require; it prints the route hint.
- **Repeated `configure` calls no longer stack notifiers.** Every consumer calls `configure` from `to_prepare`, which re-runs on every code reload. `add_notifier` now replaces an existing entry with the same identity in place: the same explicit `key:`, otherwise the same class name, or for procs and methods the same source location. The newest instance wins. `extra_notifiers` is deliberately not reset on each `configure`, because apps split configuration across several calls and a reset would silently drop notifiers added earlier.
- **gemspec declares `actionmailer` and `actionpack` (`>= 8.0`).** `require "standard_circuit"` has always loaded both, but only `railties` was declared, and railties doesn't pull in actionmailer. `activestorage` stays undeclared because the S3 service is only ever loaded by ActiveStorage's own configurator. The SDKs stay optional. The gem package now includes `app/**`.

### Deprecated
Each item below still works and warns through `StandardCircuit.deprecator`. All are removed in 0.5.
- `require "standard_circuit/health_controller"`: remove it, the controller is autoloaded. Carried in `config/routes.rb` by jumpdrive-web, fundbright-web and nutripod-web.
- `StandardCircuit.health_snapshot` and `StandardCircuit.health_overall`: use `StandardCircuit.health_report[:circuits]` / `[:status]`. No consumer calls them.
- `StandardCircuit::AdapterErrors::Faraday.caller_errors`: `Faraday::ClientError` is never tracked, so skipping it is a no-op. No consumer calls it. (`Aws.caller_errors` is kept because `default_skipped_for` uses it.)
- `StandardCircuit::ActiveStorage::S3Service`: use `ActiveStorage::Service::StandardCircuitS3Service`, or `service: StandardCircuitS3` in storage.yml. No consumer references it.

## [0.3.1] - 2026-09-24

Two behaviour changes — both are bug fixes, but both change numbers or breaker behaviour you may be alerting on.

### Fixed
- **Circuit-open requests were counted twice in `<metric_prefix>.request`.** `Runner` already emits `<metric_prefix>.request{status: circuit_open}` when a call is rejected by a tripped or forced-open circuit; `ControllerSupport#handle_circuit_open` then emitted the same metric again when the `Stoplight::Error::RedLight` reached a controller. The controller-side emission (and the private `emit_circuit_open_metric` helper) is removed; fallback dispatch is unchanged. **Behaviour change:** `circuit_open` request counts for rejections that reach a controller drop by half, back to the true value — dashboards and alert thresholds tuned against the doubled number should be revisited.
- **S3 caller errors tripped the S3 breaker.** `ErrorTaxonomies::Aws.tracked` includes `Aws::Errors::ServiceError`, which is the superclass of `Aws::S3::Errors::AccessDenied` and `NoSuchKey` as well as of the dynamically generated 5xx errors, so a burst of missing-key lookups or permission errors opened the circuit. New `ErrorTaxonomies.default_skipped_for(tracked)` returns the AWS caller errors whenever the tracked list covers them, and `register` / `register_prefix` now use it as the default `skipped_errors`. **Behaviour change:** AWS circuits registered without `skipped_errors:` no longer count `AccessDenied` / `NoSuchKey` toward the threshold; 5xx (`ServiceUnavailable` etc.) and `Seahorse::Client::NetworkingError` still trip. An explicit `skipped_errors:` — including `[]` — always wins, and circuits for other adapters keep defaulting to `[]`.

### Added
- Specs for `NetworkErrors` and the Stripe / AWS / Faraday / SMTP `AdapterErrors` modules.
- README section on error taxonomies and the AWS `skipped_errors` default; the initializer template notes it too.

### Documentation
- **Consumer list corrected in `CLAUDE.md`: this gem has five consumers, not four.** `sidekick-web` was missing. The same entry also claimed the `workspace-os` → `jumpdrive-web` directory rename "was deferred" and pointed at `~/Workspace/rarebit-one/workspace-os`; that rename completed 2026-07-14 and the old husk is gone, so an agent following the note was looking in a directory that no longer exists. Verified against the canonical matrix in the workspace's `rollout-gem/SKILL.md`, which the new advisory `check-gem-family-drift.sh` now diffs this list against on every sweep.

## [0.3.0] - 2026-07-30

### Added
- `config.sentry_criticality_levels` — opt in to criticality-aware Sentry reporting for the built-in Sentry subscriber. Accepts `true` (the recommended map `{ critical: :error, standard: :warning, optional: :info }`), a partial Hash merged over that map, or `nil` / `false` for the previous flat behaviour. In criticality-aware mode a circuit-open report also gains `circuit` / `circuit_criticality` tags and a stable `["circuit-open", <circuit>]` fingerprint, so Sentry alert rules can page on `circuit_criticality:critical` and group one issue per breaker. Invalid criticalities and non-symbolizable levels raise `ArgumentError` at configure time rather than failing silently at alert time.

  **This is opt-in, and deliberately not the new default.** Both the level and the fingerprint feed Sentry's alerting and issue grouping, so flipping the map on at gem-upgrade time would silently re-page and re-group live issues in apps that never asked for it. Apps that leave `sentry_criticality_levels` unset get the 0.2.x report byte-for-byte — same `:warning` level, same message, no tags, no fingerprint. Host apps that hand-rolled this by setting `sentry_enabled = false` and registering their own alerter can now delete that class and set `sentry_enabled = true` + `sentry_criticality_levels = true` instead.
- `isolate_namespace StandardCircuit` on the engine, bringing it in line with every other engine gem in the family. Verified non-breaking for the aggregate health route every consumer draws (`get "/health", to: "standard_circuit/health#show"`): that path is resolved by the *application's* route set through constant lookup, which isolation does not touch, and the new `spec/integration/health_route_boot_spec.rb` boots a real Rails app and requests the route end to end so a regression fails here rather than in a consumer after release. Safe specifically because this engine is library-only — no `config/routes.rb` for the isolated `default_scope` to scope, and no ActiveRecord models for the `standard_circuit_` `table_name_prefix` to apply to.

  One consequence to know about: `StandardCircuit::HealthController` now picks up the engine's (empty) url helpers instead of the application's, so app path helpers used inside it — or inside a host subclass of it — need a `main_app.` prefix. The gem's controller only renders JSON, so nothing in-gem is affected.
- README section on `data_store`, previously undocumented. Spells out that the `Stoplight::DataStore::Memory` default is **per-process** — thresholds count per worker, `/health` reports the serving process's view, and `force_open` / `reset!` are process-local — plus the shared-store alternative for apps that want cross-process state.
- README section on Sentry reporting covering `sentry_enabled`, the new `sentry_criticality_levels` opt-in, and the "subscribe yourself" escape hatch.

### Changed
- The install generator now warns that the aggregate `get "/health", to: "standard_circuit/health#show"` route must be drawn **before** `mount StandardHealth::Engine => "/health"`. `StandardHealth::Engine` registers sub-paths only (`/alive`, `/ready`, `/diagnostics/env`) and never serves the aggregate tier itself, so an app that mounts it and assumes `/health` is covered silently has no aggregate tier — with no boot error and no failing route spec to reveal it. The warning appears in the initializer template, in the `--with-health-endpoint` health initializer next to the route line, and in the hint the generator prints. Same note added to the README's health-endpoint section.
- `.github/workflows/ci.yml` follows the shared reusable workflow at `@v2` again, matching the rest of the gem family. The previous SHA pin carried a stale rationale: it claimed to restore pre-`rarebit-one/.github#14` job names for branch protection, but `main`'s protection now requires the *post*-#14 names (`ci / lint`, `ci / test-matrix (4.0.x)`) and the pinned revision's `reusable-gem-ci.yml` is byte-identical to `@v2` — so it was neither restoring old names nor changing any check name. It did honour `extra-lint-commands`, so the brakeman / bundler-audit gate was live throughout.

## [0.2.0] - 2026-04-28

### Added
- Rails event emission for every circuit-breaker lifecycle moment. The `StandardCircuit::Runner` (via a small internal `NotifierBridge` registered with Stoplight) now emits five events as host apps' breakers change state:
  - `standard_circuit.circuit.opened` — RED transition (the "alert me" event)
  - `standard_circuit.circuit.closed` — GREEN transition (recovery)
  - `standard_circuit.circuit.degraded` — YELLOW transition (half-open probe)
  - `standard_circuit.circuit.fallback_invoked` — Runner returned a fallback rather than raising RedLight
  - `standard_circuit.circuit.registered` — `Config#register` / `register_prefix` was called

  Payloads carry `circuit:`, `from_color:`, `to_color:`, `criticality:`, and (when applicable) `error_class:` / `error_message:` / `reason:`.
- `standard_circuit.run.completed` event. Per-call complement to the lifecycle events above — fires once per wrapped `StandardCircuit.run` invocation with `circuit:`, `status:` (`:success` / `:failure` / `:circuit_open`), `duration_ms:`, `criticality:`, `error_class:`, and `error_message:`. The right hook for cost-tracking, p95 latency, and per-circuit success-rate dashboards. (`force_closed` runs are intentionally not emitted — that path bypasses the runner.) Routed through the same `EventEmitter` as the lifecycle events, so subscribers get it on `Rails.event` (8.1+) or `ActiveSupport::Notifications` automatically; `duration_ms` is in the payload (not `event.duration`) so backend choice doesn't matter.
- Dual-backend dispatch in `StandardCircuit::EventEmitter`: emits through `Rails.event.notify` on Rails 8.1+ and falls back to `ActiveSupport::Notifications.instrument` on older Rails. Detection happens at call time, so the gem still loads cleanly before Rails has booted and before `railties` is even required.
- `StandardCircuit::Engine` Railtie that registers the internal subscribers (Logger / Sentry / Metrics) plus any `extra_notifiers` at boot via the `standard_circuit.subscribers` initializer.
- `StandardCircuit.subscribers` accessor + `Subscribers#setup!` / `#teardown!` for tests and host apps that need to re-register listeners after mutating config.
- `rails g standard_circuit:install` — Rails install generator. Writes `config/initializers/standard_circuit.rb` with commented-out examples covering the public Config DSL (`register`, `register_prefix`, notifiers, data store, criticality). Idempotent: re-running on an existing initializer skips with a clear message; pass `--force` to overwrite. Pass `--with-health-endpoint` to also write `config/initializers/standard_circuit_health.rb` (which `require`s the opt-in `HealthController`) and print the route line to add to `config/routes.rb`. The generator does not auto-edit `routes.rb` — too invasive — so consumers paste the printed line themselves.
- README section on streaming responses and non-controller contexts: shows the recipe for catching `Stoplight::Error::RedLight` inside a `Live` controller's streaming proc (where `circuit_open_fallback` can't render over an open response), and notes the equivalent pattern for background jobs.

### Changed
- **BREAKING.** `StandardCircuit::Notifiers::{Logger,Sentry,Metrics}` are no longer Stoplight-shaped notifiers. Each now exposes `call(event_name, payload)` and is registered as an event subscriber by the gem's Railtie. They are still considered an internal implementation detail — host apps that want their own behaviour should subscribe to the `standard_circuit.*` namespace directly rather than instantiating these classes.
- **BREAKING.** `Config#add_notifier` now requires the supplied object to respond to `call(event_name, payload)`. Stoplight-shaped 4-arg notifiers from 0.1.x are rejected with `ArgumentError`. Callers should subscribe via `Rails.event.subscribe` / `ActiveSupport::Notifications.subscribe("standard_circuit.*")` for full control, or pass a lambda to `add_notifier` for the simple case.
- **BREAKING.** Stoplight only sees a single internal `StandardCircuit::NotifierBridge` notifier now; host apps that previously read `StandardCircuit.config.notifiers` to build their own Stoplight light will need to register against the new event namespace instead.
- README "Quick start" and the `rails g standard_circuit:install` initializer template now use `ErrorTaxonomies::*.tracked` consistently (the S3 example in the template still showed the pre-0.1.2 `AdapterErrors::Aws.server_errors` form).
- The install template's "Extra notifiers" example now uses `add_notifier` with a 2-arg `call(name, payload)` callable, matching the contract `Config#add_notifier` enforces. The previous example wrote directly to `extra_notifiers <<` with a 1-arg lambda — both bypassing validation and using the wrong arity, so any consumer who uncommented it would get `ArgumentError: wrong number of arguments` on the first emitted event.
- `lib/standard_circuit/rspec.rb` now also tears down event subscribers between examples so a spec that subscribes manually doesn't leak listeners into the next.
- CI and release workflows migrated to the shared `rarebit-one/.github` reusable workflows (`reusable-gem-ci.yml@v1`, `reusable-gem-release.yml@v1`); `.github/workflows/ci.yml` and `release.yml` are now thin shims.

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

