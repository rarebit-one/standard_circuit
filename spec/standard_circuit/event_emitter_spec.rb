require "spec_helper"

RSpec.describe StandardCircuit::EventEmitter do
  describe ".emit" do
    let(:payload) { { circuit: "stripe", from_color: "green", to_color: "red" } }

    context "when Rails.event is available" do
      it "routes through Rails.event.notify" do
        captured = nil
        rails_event = Object.new
        rails_event.define_singleton_method(:respond_to?) { |m, *| m == :notify || super(m) }
        rails_event.define_singleton_method(:notify) do |name, **payload|
          captured = { name: name, payload: payload }
        end
        rails_const = Module.new do
          define_singleton_method(:respond_to?) { |m, *| m == :event || super(m) }
        end
        rails_const.define_singleton_method(:event) { rails_event }
        stub_const("Rails", rails_const)

        described_class.emit("standard_circuit.circuit.opened", payload)

        expect(captured).to eq(name: "standard_circuit.circuit.opened", payload: payload)
      end
    end

    context "when Rails.event is unavailable" do
      it "falls back to ActiveSupport::Notifications.instrument" do
        hide_const("Rails") if defined?(::Rails)

        events = []
        callback = ->(name, _start, _finish, _id, payload) { events << [ name, payload ] }
        ActiveSupport::Notifications.subscribed(callback, "standard_circuit.circuit.opened") do
          described_class.emit("standard_circuit.circuit.opened", payload)
        end

        expect(events).to eq([ [ "standard_circuit.circuit.opened", payload ] ])
      end
    end

    it "swallows subscriber failures so circuit observability cannot break a request" do
      faulty_rails = Module.new do
        define_singleton_method(:respond_to?) { |m, *| m == :event || super(m) }
      end
      faulty_event = Object.new
      faulty_event.define_singleton_method(:respond_to?) { |m, *| m == :notify || super(m) }
      faulty_event.define_singleton_method(:notify) { |*| raise "subscriber blew up" }
      faulty_rails.define_singleton_method(:event) { faulty_event }
      stub_const("Rails", faulty_rails)

      expect {
        described_class.emit("standard_circuit.circuit.opened", { circuit: "x" })
      }.not_to raise_error
    end
  end

  describe ".rails_event_available?" do
    it "is false when Rails is not defined" do
      hide_const("Rails") if defined?(::Rails)

      expect(described_class).not_to be_rails_event_available
    end

    it "is false when Rails.event does not exist" do
      stub_const("Rails", Module.new)

      expect(described_class).not_to be_rails_event_available
    end

    it "is true when Rails.event responds to :notify" do
      rails_event = Object.new
      rails_event.define_singleton_method(:respond_to?) { |m, *| m == :notify || super(m) }
      rails_event.define_singleton_method(:notify) { |*| nil }
      rails_const = Module.new
      rails_const.define_singleton_method(:respond_to?) { |m, *| m == :event || super(m) }
      rails_const.define_singleton_method(:event) { rails_event }
      stub_const("Rails", rails_const)

      expect(described_class).to be_rails_event_available
    end
  end
end
