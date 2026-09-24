require "rails/generators"

module StandardCircuit
  module Generators
    # Installs StandardCircuit in a host Rails application.
    #
    # By default, writes config/initializers/standard_circuit.rb with
    # commented-out examples covering the public Config DSL.
    #
    # When +--with-health-endpoint+ is passed, also prints the route line the
    # host should add to config/routes.rb to expose the endpoint. (Before 0.4
    # it also wrote config/initializers/standard_circuit_health.rb to require
    # the controller; the engine now autoloads it, so no file is needed.)
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

        Pass --with-health-endpoint to also print the route line to add to
        config/routes.rb. The health controller is autoloaded by the engine,
        so the route is all you need.

        The generator is idempotent — already-installed initializers are
        skipped with a clear message. Pass --force to overwrite.
      DESC

      class_option :with_health_endpoint, type: :boolean, default: false,
        desc: "Also print the config/routes.rb line for the health endpoint"

      def create_initializer_file
        path = "config/initializers/standard_circuit.rb"
        if File.exist?(File.join(destination_root, path)) && !options[:force]
          say_status("skip", "#{path} already present, skipping (use --force to overwrite)", :yellow)
          return
        end

        template "initializer.rb.tt", path
      end

      def print_health_route_hint
        return unless options[:with_health_endpoint]

        say ""
        say "=" * 79
        say "StandardCircuit health endpoint"
        say ""
        say "Add the following to config/routes.rb to expose the endpoint (the"
        say "controller is autoloaded by the engine — no require needed):"
        say ""
        say '  get "/health", to: "standard_circuit/health#show"'
        say ""
        say "If you also mount StandardHealth::Engine at \"/health\", draw the"
        say "line above BEFORE the mount. That engine serves sub-paths only"
        say "(/alive, /ready, /diagnostics/env), never the aggregate tier — so"
        say "an app that mounts it and assumes \"/health\" is covered silently has"
        say "no aggregate tier, with no boot error to warn you."
        say ""
        say "The controller returns 503 when the rolled-up circuit health is"
        say ":critical and 200 otherwise — wire it up to your load balancer."
        say "=" * 79
        say ""
      end
    end
  end
end
