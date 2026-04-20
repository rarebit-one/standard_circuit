require "spec_helper"

RSpec.describe StandardCircuit::Notifiers::Sentry do
  let(:light) { instance_double(Stoplight::Domain::Light, name: "stripe") }
  let(:error) { StandardError.new("upstream down") }

  describe "#notify" do
    context "on GREEN -> RED transition" do
      it "captures a warning-level Sentry message with circuit metadata" do
        captured = capture_sentry_message do
          described_class.new.notify(light, "green", "red", error)
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

    context "on YELLOW -> RED transition" do
      it "still captures (any transition into red counts)" do
        captured = capture_sentry_message do
          described_class.new.notify(light, "yellow", "red", error)
        end

        expect(captured).not_to be_nil
      end
    end

    context "on non-red transitions" do
      it "does not capture" do
        captured = capture_sentry_message do
          described_class.new.notify(light, "red", "green", nil)
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
