require "spec_helper"

RSpec.describe StandardCircuit::Notifiers::Sentry do
  let(:opened_payload) do
    {
      circuit: "stripe",
      from_color: "green",
      to_color: "red",
      criticality: :critical,
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

    it "does nothing when Sentry is not loaded" do
      hide_const("Sentry") if defined?(::Sentry)
      expect(described_class.new.call("standard_circuit.circuit.opened", opened_payload)).to be_nil
    end
  end

  # The flat shape is what every 0.2.x consumer is running. It must survive a
  # gem bump untouched — no criticality in the message, no tags, no fingerprint
  # (fingerprints change Sentry issue grouping).
  describe "flat mode (default — no opt-in)" do
    it "reports :warning regardless of criticality" do
      StandardCircuit::Config::CRITICALITIES.each do |criticality|
        captured = capture_sentry_message do
          described_class.new.call(
            "standard_circuit.circuit.opened",
            opened_payload.merge(criticality: criticality)
          )
        end

        expect(captured[:level]).to eq(:warning)
      end
    end

    it "does not add tags, a fingerprint, or criticality to the report" do
      captured = capture_sentry_message do
        described_class.new.call("standard_circuit.circuit.opened", opened_payload)
      end

      expect(captured).not_to have_key(:tags)
      expect(captured).not_to have_key(:fingerprint)
      expect(captured[:extra]).not_to have_key(:criticality)
      expect(captured[:message]).to eq("Circuit breaker opened: stripe")
    end
  end

  describe "criticality-aware mode" do
    let(:notifier) { described_class.new(levels: described_class::DEFAULT_LEVELS) }

    {
      critical: :error,
      standard: :warning,
      optional: :info
    }.each do |criticality, expected_level|
      it "maps criticality #{criticality.inspect} to Sentry level #{expected_level.inspect}" do
        captured = capture_sentry_message do
          notifier.call("standard_circuit.circuit.opened", opened_payload.merge(criticality: criticality))
        end

        expect(captured[:level]).to eq(expected_level)
      end
    end

    it "covers every registrable criticality so a new one can't silently fall back" do
      expect(described_class::DEFAULT_LEVELS.keys)
        .to match_array(StandardCircuit::Config::CRITICALITIES)
    end

    it "falls back to :warning for an unrecognised criticality" do
      captured = capture_sentry_message do
        notifier.call("standard_circuit.circuit.opened", opened_payload.merge(criticality: :bogus))
      end

      expect(captured[:level]).to eq(described_class::DEFAULT_LEVEL)
    end

    it "treats a missing criticality as :standard" do
      captured = capture_sentry_message do
        notifier.call("standard_circuit.circuit.opened", opened_payload.except(:criticality))
      end

      expect(captured[:level]).to eq(:warning)
      expect(captured[:message]).to eq("Circuit breaker opened: stripe (standard)")
    end

    it "honours a custom level map" do
      captured = capture_sentry_message do
        described_class.new(levels: { critical: :fatal })
          .call("standard_circuit.circuit.opened", opened_payload)
      end

      expect(captured[:level]).to eq(:fatal)
    end

    it "tags the report with circuit and criticality so alert rules can route" do
      captured = capture_sentry_message do
        notifier.call("standard_circuit.circuit.opened", opened_payload)
      end

      expect(captured[:tags]).to eq(circuit: "stripe", circuit_criticality: "critical")
    end

    it "fingerprints per circuit so Sentry groups one issue per breaker" do
      captured = capture_sentry_message do
        notifier.call("standard_circuit.circuit.opened", opened_payload)
      end

      expect(captured[:fingerprint]).to eq([ "circuit-open", "stripe" ])
    end

    it "includes criticality alongside the circuit metadata in extra" do
      captured = capture_sentry_message do
        notifier.call("standard_circuit.circuit.opened", opened_payload)
      end

      expect(captured[:extra]).to include(
        circuit: "stripe",
        criticality: :critical,
        from_color: "green",
        to_color: "red",
        error_class: "StandardError",
        error_message: "upstream down"
      )
    end

    it "omits absent error metadata rather than sending nils" do
      captured = capture_sentry_message do
        notifier.call(
          "standard_circuit.circuit.opened",
          circuit: "smtp", from_color: "green", to_color: "red", criticality: :optional
        )
      end

      expect(captured[:extra].keys).to contain_exactly(:circuit, :from_color, :to_color, :criticality)
    end

    it "still ignores non-opened transitions" do
      captured = capture_sentry_message do
        notifier.call("standard_circuit.circuit.closed", opened_payload.merge(to_color: "green"))
      end

      expect(captured).to be_nil
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
