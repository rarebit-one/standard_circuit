require "spec_helper"

RSpec.describe StandardCircuit::Mailer::Railtie do
  describe ".install" do
    let(:mailer_class) { Class.new(ActionMailer::Base) }

    it "does not wipe :standard_circuit_settings when the host app has already registered" do
      # Simulates the host app's env-file `on_load(:action_mailer)` block:
      # the app calls `add_delivery_method` and writes circuit settings.
      mailer_class.add_delivery_method :standard_circuit, StandardCircuit::Mailer::DeliveryMethod
      mailer_class.standard_circuit_settings = { circuit: :sendgrid }

      # The gem's Railtie on_load fires next. Without the idempotency guard,
      # ActionMailer's `add_delivery_method` would reset settings to `{}`,
      # causing `KeyError: key not found: :circuit` at delivery time.
      described_class.install(mailer_class)

      expect(mailer_class.standard_circuit_settings).to eq(circuit: :sendgrid)
    end

    it "registers :standard_circuit when the host app has not pre-registered" do
      described_class.install(mailer_class)

      expect(mailer_class.delivery_methods)
        .to include(standard_circuit: StandardCircuit::Mailer::DeliveryMethod)
      expect(mailer_class.standard_circuit_settings).to eq({})
    end
  end

  describe "initializer ordering" do
    it "declares standard_circuit.action_mailer to run before action_mailer.set_configs" do
      # Rails' `action_mailer.set_configs` forwards
      # `config.action_mailer.standard_circuit_settings=` to ActionMailer::Base.
      # That assignment fails with NoMethodError unless the accessor already
      # exists, which only happens after our `add_delivery_method` call. The
      # `before:` hint guarantees the right ordering so apps can configure
      # the gem with `config.action_mailer.standard_circuit_settings = {...}`
      # without resorting to monkey-patches against this Initializer's @before.
      init = described_class.initializers
        .find { |i| i.name == "standard_circuit.action_mailer" }

      expect(init).not_to be_nil
      expect(init.before).to eq("action_mailer.set_configs")
    end
  end
end
