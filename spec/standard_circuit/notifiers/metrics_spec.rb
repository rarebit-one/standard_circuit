require "spec_helper"

RSpec.describe StandardCircuit::Notifiers::Metrics do
  describe "#call" do
    {
      "standard_circuit.circuit.opened"   => "opened",
      "standard_circuit.circuit.closed"   => "closed",
      "standard_circuit.circuit.degraded" => "half_open"
    }.each do |event_name, state|
      it "emits state=#{state} for #{event_name}" do
        captured = capture_metric do
          described_class.new(metric_prefix: "external").call(event_name,
            circuit: "stripe", from_color: "green", to_color: state)
        end

        expect(captured[:name]).to eq("external.circuit_breaker")
        expect(captured[:attributes]).to eq(service: "stripe", state: state)
      end
    end

    it "honors a custom metric prefix" do
      captured = capture_metric do
        described_class.new(metric_prefix: "web").call("standard_circuit.circuit.opened",
          circuit: "stripe", from_color: "green", to_color: "red")
      end

      expect(captured[:name]).to eq("web.circuit_breaker")
    end

    it "ignores unrelated events" do
      captured = capture_metric do
        described_class.new.call("standard_circuit.circuit.fallback_invoked",
          circuit: "stripe", reason: :circuit_open)
      end

      expect(captured).to be_nil
    end
  end

  def capture_metric
    captured = nil
    stub_metrics = Module.new do
      define_singleton_method(:count) do |name, **opts|
        captured = { name: name, **opts }
      end
    end
    stub_const("Sentry::Metrics", stub_metrics)
    yield
    captured
  end
end
