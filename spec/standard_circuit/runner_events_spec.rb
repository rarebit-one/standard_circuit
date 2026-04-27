require "spec_helper"

RSpec.describe StandardCircuit::Runner do
  describe "Rails event emission" do
    before do
      hide_const("Rails") if defined?(::Rails)
      StandardCircuit.configure do |c|
        c.register(:flaky, threshold: 1, cool_off_time: 10,
                   tracked_errors: [ RuntimeError ])
      end
    end

    it "emits standard_circuit.circuit.opened when the circuit trips" do
      events = []
      callback = ->(name, _s, _f, _i, payload) { events << [ name, payload ] }
      ActiveSupport::Notifications.subscribed(callback, /\Astandard_circuit\.circuit\./) do
        expect { StandardCircuit.run(:flaky) { raise "boom" } }.to raise_error(RuntimeError)
      end

      opened = events.find { |(name, _)| name == "standard_circuit.circuit.opened" }
      expect(opened).not_to be_nil
      expect(opened[1]).to include(
        circuit: "flaky",
        to_color: Stoplight::Color::RED,
        criticality: :standard,
        error_class: "RuntimeError",
        error_message: "boom"
      )
    end

    it "emits standard_circuit.circuit.fallback_invoked when forced open and a fallback fires" do
      events = []
      callback = ->(name, _s, _f, _i, payload) { events << [ name, payload ] }
      ActiveSupport::Notifications.subscribed(callback, /\Astandard_circuit\.circuit\.fallback_invoked\z/) do
        StandardCircuit.force_open(:flaky)
        StandardCircuit.run(:flaky, fallback: ->(_e) { :recovered }) { :never }
      end

      expect(events.size).to eq(1)
      expect(events.first[1]).to include(circuit: "flaky", reason: :forced_open)
    end

    it "emits standard_circuit.circuit.registered for register" do
      events = []
      callback = ->(name, _s, _f, _i, payload) { events << [ name, payload ] }
      ActiveSupport::Notifications.subscribed(callback, "standard_circuit.circuit.registered") do
        StandardCircuit.config.register(:new_one, threshold: 2, cool_off_time: 5,
                                        tracked_errors: [ RuntimeError ],
                                        criticality: :optional)
      end

      expect(events.size).to eq(1)
      expect(events.first[1]).to include(circuit: "new_one", criticality: :optional, scope: :name)
    end

    it "emits standard_circuit.circuit.registered with scope: :prefix for register_prefix" do
      events = []
      callback = ->(name, _s, _f, _i, payload) { events << [ name, payload ] }
      ActiveSupport::Notifications.subscribed(callback, "standard_circuit.circuit.registered") do
        StandardCircuit.config.register_prefix(:s3, threshold: 3, cool_off_time: 10,
                                               tracked_errors: [ RuntimeError ])
      end

      expect(events.size).to eq(1)
      expect(events.first[1]).to include(circuit: "s3", scope: :prefix)
    end
  end
end
