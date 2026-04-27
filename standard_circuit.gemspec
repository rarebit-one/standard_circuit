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
    Dir["lib/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.required_ruby_version = ">= 4.0"

  spec.add_dependency "stoplight", "~> 5.8"
  spec.add_dependency "concurrent-ruby", "~> 1.3"
  spec.add_dependency "sentry-ruby", ">= 5.17"
  spec.add_dependency "railties", ">= 8.0"
end
