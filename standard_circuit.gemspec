require_relative "lib/standard_circuit/version"

Gem::Specification.new do |spec|
  spec.name        = "standard_circuit"
  spec.version     = StandardCircuit::VERSION
  spec.authors     = [ "Jaryl Sim" ]
  spec.email       = [ "code@jaryl.dev" ]
  spec.homepage    = "https://github.com/rarebit-one/standard_circuit"
  spec.summary     = "Circuit breaker primitives for Rails apps, built on stoplight."
  spec.description = "StandardCircuit wraps the stoplight gem with opinionated error taxonomy, Sentry notifiers, ActiveStorage S3 and ActionMailer adapters, and test helpers shared across Rails apps."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rarebit-one/standard_circuit"
  spec.metadata["changelog_uri"] = "https://github.com/rarebit-one/standard_circuit/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/rarebit-one/standard_circuit/issues"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["app/**/*", "lib/**/*", "LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.required_ruby_version = ">= 4.0"

  spec.add_dependency "stoplight", "~> 5.8"
  spec.add_dependency "concurrent-ruby", "~> 1.3"
  spec.add_dependency "sentry-ruby", ">= 5.17"
  spec.add_dependency "railties", ">= 8.0"
  # `require "standard_circuit"` loads the mailer delivery method + Railtie
  # (action_mailer, which brings activejob for `mailer_retry`) and
  # ControllerSupport (action_controller) unconditionally, so both are real
  # runtime dependencies rather than optional integrations.
  spec.add_dependency "actionmailer", ">= 8.0"
  spec.add_dependency "actionpack", ">= 8.0"
  # Deliberately NOT declared, because they are only ever loaded by the thing
  # that needs them and so are always present when they're loaded:
  #   activestorage — the StandardCircuitS3 service file is required only by
  #                   ActiveStorage's own Configurator (storage.yml).
  #   aws-sdk-s3 / postmark / stripe / faraday — AdapterErrors return [] when
  #                   the SDK isn't loaded; presets require their SDK on use.

  spec.add_development_dependency "brakeman"
  spec.add_development_dependency "bundler-audit"
  spec.add_development_dependency "simplecov"
end
