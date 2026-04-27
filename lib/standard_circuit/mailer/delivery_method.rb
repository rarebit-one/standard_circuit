require "action_mailer"
require_relative "circuit_open_error"

module StandardCircuit
  module Mailer
    class DeliveryMethod
      attr_accessor :settings

      def initialize(settings)
        @settings = settings
        @underlying = nil
      end

      def deliver!(mail)
        StandardCircuit.run(circuit_name) do
          underlying_instance.deliver!(mail)
        end
      rescue Stoplight::Error::RedLight
        raise retry_error_class.new(
          recipients: Array(mail.to),
          subject: mail.subject
        )
      end

      private

      def circuit_name
        settings.fetch(:circuit)
      end

      def retry_error_class
        settings.fetch(:retry_error_class, StandardCircuit::Mailer::CircuitOpenError)
      end

      def underlying_instance
        @underlying ||= resolve_underlying
      end

      def resolve_underlying
        target = settings.fetch(:underlying)
        return target unless target.is_a?(Symbol)

        registry = ::ActionMailer::Base.delivery_methods
        klass = registry.fetch(target) do
          raise ArgumentError, "unknown delivery method #{target.inspect}. Registered: #{registry.keys.inspect}"
        end
        klass.new(settings.fetch(:underlying_settings, {}))
      end
    end

    if defined?(::Rails::Railtie)
      class Railtie < ::Rails::Railtie
        # ActionMailer's `add_delivery_method` unconditionally resets
        # `<symbol>_settings` to its `default_options` arg. If the host app
        # has already registered :standard_circuit (e.g. from its own
        # `on_load(:action_mailer)` block in an env file, queued earlier),
        # calling `add_delivery_method` again would wipe the settings the
        # app just wrote — causing `KeyError: key not found: :circuit` at
        # delivery time. Skip if already registered. (This guard assumes the
        # host app registers first; if you call `add_delivery_method` from
        # `after_initialize` or otherwise after the gem's Railtie hook fires,
        # use `standard_circuit_settings=` directly to avoid the reset.)
        def self.install(mailer_class)
          return if mailer_class.delivery_methods.key?(:standard_circuit)

          mailer_class.add_delivery_method :standard_circuit, StandardCircuit::Mailer::DeliveryMethod
        end

        initializer "standard_circuit.action_mailer" do
          ActiveSupport.on_load(:action_mailer) do
            StandardCircuit::Mailer::Railtie.install(self)
          end
        end
      end
    end
  end
end
