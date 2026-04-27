require "spec_helper"

RSpec.describe StandardCircuit::NotifierBridge do
  let(:config) do
    StandardCircuit::Config.new.tap do |c|
      c.register(:stripe, threshold: 1, cool_off_time: 10, criticality: :critical,
                 tracked_errors: [ RuntimeError ])
    end
  end
  let(:bridge) { described_class.new(config) }
  let(:light) { instance_double(Stoplight::Domain::Light, name: "stripe") }

  it "emits opened on RED transitions with the error context" do
    captured = capture_event do
      bridge.notify(light, "green", Stoplight::Color::RED, RuntimeError.new("boom"))
    end

    expect(captured[:name]).to eq("standard_circuit.circuit.opened")
    expect(captured[:payload]).to include(
      circuit: "stripe",
      from_color: "green",
      to_color: Stoplight::Color::RED,
      criticality: :critical,
      error_class: "RuntimeError",
      error_message: "boom"
    )
  end

  it "emits closed on GREEN transitions" do
    captured = capture_event do
      bridge.notify(light, "yellow", Stoplight::Color::GREEN, nil)
    end

    expect(captured[:name]).to eq("standard_circuit.circuit.closed")
  end

  it "emits degraded on YELLOW transitions" do
    captured = capture_event do
      bridge.notify(light, "red", Stoplight::Color::YELLOW, nil)
    end

    expect(captured[:name]).to eq("standard_circuit.circuit.degraded")
  end

  it "is a no-op for unmapped to_colors" do
    captured = capture_event do
      bridge.notify(light, "green", "purple", nil)
    end
    expect(captured).to be_nil
  end

  # Scope capture to color-transition events so the let(:config)'s register
  # call (which fires standard_circuit.circuit.registered) doesn't leak into
  # the assertion.
  def capture_event
    captured = nil
    pattern = /\Astandard_circuit\.circuit\.(opened|closed|degraded)\z/
    callback = ->(name, _s, _f, _i, payload) { captured = { name: name, payload: payload } }
    ActiveSupport::Notifications.subscribed(callback, pattern) do
      hide_const("Rails") if defined?(::Rails)
      yield
    end
    captured
  end
end
