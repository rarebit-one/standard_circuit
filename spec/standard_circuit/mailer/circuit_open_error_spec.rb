require "spec_helper"
require "standard_circuit/mailer/circuit_open_error"

RSpec.describe StandardCircuit::Mailer::CircuitOpenError do
  describe "#initialize" do
    it "exposes recipients and subject via attr_readers" do
      error = described_class.new(recipients: [ "user@example.com" ], subject: "Welcome")

      expect(error.recipients).to eq([ "user@example.com" ])
      expect(error.subject).to eq("Welcome")
    end

    it "holds recipients verbatim without coercing (caller supplies an array)" do
      # DeliveryMethod#deliver! passes Array(mail.to); we don't double-coerce.
      error = described_class.new(recipients: [ "a@example.com", "b@example.com" ], subject: "Hi")

      expect(error.recipients).to eq([ "a@example.com", "b@example.com" ])
    end

    it "is a StandardError subclass" do
      expect(described_class.ancestors).to include(StandardError)
    end

    it "builds a descriptive message including recipients and subject" do
      error = described_class.new(recipients: [ "user@example.com" ], subject: "Welcome")

      expect(error.message).to include("Circuit breaker is open")
      expect(error.message).to include("user@example.com")
      expect(error.message).to include("Welcome")
    end

    it "requires recipients: and subject: keyword arguments" do
      expect { described_class.new }.to raise_error(ArgumentError)
    end
  end
end
