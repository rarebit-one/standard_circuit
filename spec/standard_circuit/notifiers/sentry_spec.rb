require "spec_helper"

RSpec.describe StandardCircuit::Notifiers::Sentry do
  let(:opened_payload) do
    {
      circuit: "stripe",
      from_color: "green",
      to_color: "red",
      error_class: "StandardError",
      error_message: "upstream down"
    }
  end

  describe "#call" do
    context "when the event is standard_circuit.circuit.opened" do
      it "captures a warning-level Sentry message with circuit metadata" do
        captured = capture_sentry_message do
          described_class.new.call("standard_circuit.circuit.opened", opened_payload)
        end

        expect(captured[:message]).to include("stripe")
        expect(captured[:level]).to eq(:warning)
        expect(captured[:extra]).to include(
          circuit: "stripe",
          from_color: "green",
          to_color: "red",
          error_class: "StandardError",
          error_message: "upstream down"
        )
      end
    end

    context "when the event is not standard_circuit.circuit.opened" do
      it "does not capture on closed transitions" do
        captured = capture_sentry_message do
          described_class.new.call(
            "standard_circuit.circuit.closed",
            circuit: "stripe", from_color: "red", to_color: "green"
          )
        end

        expect(captured).to be_nil
      end

      it "does not capture on degraded transitions" do
        captured = capture_sentry_message do
          described_class.new.call(
            "standard_circuit.circuit.degraded",
            circuit: "stripe", from_color: "red", to_color: "yellow"
          )
        end

        expect(captured).to be_nil
      end
    end
  end

  def capture_sentry_message
    captured = nil
    stub_sentry = Module.new do
      define_singleton_method(:respond_to?) { |method, *| method == :capture_message || super(method) }
      define_singleton_method(:capture_message) do |message, **opts|
        captured = { message: message, **opts }
      end
    end
    stub_const("Sentry", stub_sentry)
    yield
    captured
  end
end
