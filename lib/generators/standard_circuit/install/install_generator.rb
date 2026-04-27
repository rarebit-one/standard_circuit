require "rails/generators"

module StandardCircuit
  module Generators
    # Installs StandardCircuit in a host Rails application.
    #
    # By default, writes config/initializers/standard_circuit.rb with
    # commented-out examples covering the public Config DSL.
    #
    # When +--with-health-endpoint+ is passed, also writes
    # config/initializers/standard_circuit_health.rb (which requires the
    # opt-in HealthController) and prints the route line the host should
    # add to config/routes.rb to expose the endpoint.
    #
    # Idempotent: re-running on an existing initializer logs and skips. Pass
    # +--force+ to overwrite.
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc <<~DESC
        Installs StandardCircuit. By default this writes
        config/initializers/standard_circuit.rb with commented-out examples
        covering circuit registration, prefix registration, and notifier
        wiring.

        Pass --with-health-endpoint to also write
        config/initializers/standard_circuit_health.rb (which requires the
        opt-in HealthController) and print the route line to add to
        config/routes.rb.

        The generator is idempotent — already-installed initializers are
        skipped with a clear message. Pass --force to overwrite.
      DESC

      class_option :with_health_endpoint, type: :boolean, default: false,
        desc: "Also create config/initializers/standard_circuit_health.rb and print the route hint"

      def create_initializer_file
        path = "config/initializers/standard_circuit.rb"
        if File.exist?(File.join(destination_root, path)) && !options[:force]
          say_status("skip", "#{path} already present, skipping (use --force to overwrite)", :yellow)
          return
        end

        template "initializer.rb.tt", path
      end

      def create_health_initializer_file
        return unless options[:with_health_endpoint]

        path = "config/initializers/standard_circuit_health.rb"
        if File.exist?(File.join(destination_root, path)) && !options[:force]
          say_status("skip", "#{path} already present, skipping (use --force to overwrite)", :yellow)
        else
          template "health_initializer.rb.tt", path
        end
      end

      def print_health_route_hint
        return unless options[:with_health_endpoint]

        say ""
        say "=" * 79
        say "StandardCircuit health endpoint installed."
        say ""
        say "Add the following to config/routes.rb to expose the endpoint:"
        say ""
        say '  get "/health", to: "standard_circuit/health#show"'
        say ""
        say "The controller returns 503 when the rolled-up circuit health is"
        say ":critical and 200 otherwise — wire it up to your load balancer."
        say "=" * 79
        say ""
      end
    end
  end
end
