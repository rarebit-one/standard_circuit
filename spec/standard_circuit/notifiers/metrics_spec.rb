require "spec_helper"

RSpec.describe StandardCircuit::Notifiers::Metrics do
  let(:light) { instance_double(Stoplight::Domain::Light, name: "stripe") }

  describe "#notify" do
    {
      "red" => "opened",
      "green" => "closed",
      "yellow" => "half_open"
    }.each do |color, state|
      it "emits state=#{state} for color=#{color}" do
        captured = capture_metric do
          described_class.new(metric_prefix: "external").notify(light, "green", color, nil)
        end

        expect(captured[:name]).to eq("external.circuit_breaker")
        expect(captured[:attributes]).to eq(service: "stripe", state: state)
      end
    end

    it "honors a custom metric prefix" do
      captured = capture_metric do
        described_class.new(metric_prefix: "web").notify(light, "green", "red", nil)
      end

      expect(captured[:name]).to eq("web.circuit_breaker")
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
