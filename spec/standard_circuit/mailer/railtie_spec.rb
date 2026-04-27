require "spec_helper"

RSpec.describe StandardCircuit::Mailer::Railtie, ".install" do
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
