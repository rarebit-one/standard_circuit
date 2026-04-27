require "spec_helper"
require "logger"

RSpec.describe StandardCircuit::Notifiers::Logger do
  let(:io) { StringIO.new }
  let(:logger) { ::Logger.new(io) }

  let(:opened_payload) do
    {
      circuit: "stripe",
      from_color: "green",
      to_color: "red",
      error_class: "StandardError",
      error_message: "boom"
    }
  end

  describe "#call" do
    it "logs transitions with context" do
      described_class.new(logger).call("standard_circuit.circuit.opened", opened_payload)

      expect(io.string).to include("stripe", "green", "red", "StandardError", "boom")
    end

    it "logs at warn level when the circuit opens" do
      described_class.new(logger).call("standard_circuit.circuit.opened", opened_payload)

      expect(io.string).to include("WARN")
    end

    it "logs at info level on non-opened transitions" do
      described_class.new(logger).call(
        "standard_circuit.circuit.closed",
        circuit: "stripe", from_color: "yellow", to_color: "green"
      )

      expect(io.string).to include("INFO")
    end

    it "omits the error fragment when no error is in the payload" do
      described_class.new(logger).call(
        "standard_circuit.circuit.degraded",
        circuit: "stripe", from_color: "red", to_color: "yellow"
      )

      expect(io.string).not_to include("because")
    end
  end
end
