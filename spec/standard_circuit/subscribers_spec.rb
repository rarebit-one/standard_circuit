require "spec_helper"

RSpec.describe StandardCircuit::Subscribers do
  describe "ActiveSupport::Notifications fallback path" do
    before { hide_const("Rails") if defined?(::Rails) }

    it "registers internal subscribers (Logger / Sentry / Metrics) on setup!" do
      io = StringIO.new
      StandardCircuit.config.logger = ::Logger.new(io)
      StandardCircuit.config.sentry_enabled = false

      StandardCircuit.subscribers.setup!

      ActiveSupport::Notifications.instrument("standard_circuit.circuit.opened",
        circuit: "stripe", from_color: "green", to_color: "red",
        error_class: "RuntimeError", error_message: "boom")

      expect(io.string).to include("stripe", "RuntimeError", "boom")
    end

    it "registers extra notifiers that respond to call(name, payload)" do
      received = []
      subscriber = ->(name, payload) { received << [ name, payload ] }
      StandardCircuit.config.add_notifier(subscriber)
      StandardCircuit.subscribers.setup!

      ActiveSupport::Notifications.instrument("standard_circuit.circuit.closed",
        circuit: "stripe", from_color: "yellow", to_color: "green")

      expect(received).to eq([ [
        "standard_circuit.circuit.closed",
        { circuit: "stripe", from_color: "yellow", to_color: "green" }
      ] ])
    end

    it "rejects extras that don't respond to :call" do
      legacy = Class.new do
        def notify(_l, _f, _t, _e); end
      end.new

      expect {
        StandardCircuit.config.add_notifier(legacy)
      }.to raise_error(ArgumentError, /must respond to/)
    end

    it "teardown! removes all listeners" do
      received = []
      StandardCircuit.config.add_notifier(->(name, _p) { received << name })
      StandardCircuit.subscribers.setup!

      StandardCircuit.subscribers.teardown!

      ActiveSupport::Notifications.instrument("standard_circuit.circuit.opened", circuit: "x")
      expect(received).to be_empty
    end

    it "ignores events outside the standard_circuit namespace" do
      received = []
      StandardCircuit.config.add_notifier(->(name, _p) { received << name })
      StandardCircuit.subscribers.setup!

      ActiveSupport::Notifications.instrument("other.event", circuit: "x")

      expect(received).to be_empty
    end
  end
end
