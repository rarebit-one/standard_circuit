require "spec_helper"

# Stoplight 6 registers lights once per name inside a system, rejects
# conflicting re-registration, takes only named error matchers at registration
# and only whole seconds for durations. These pin the behaviour the runner
# keeps from the stoplight 5 era despite all of that.
RSpec.describe StandardCircuit::Runner do
  describe "on stoplight 6" do
    def trip(name, error = RuntimeError.new("boom"))
      StandardCircuit.run(name) { raise error }
    rescue StandardError
      nil
    end

    it "tracks anonymous error classes and procs, which stoplight 6 only accepts per run" do
      anonymous = Class.new(StandardError)
      StandardCircuit.configure do |c|
        c.register(:anon, threshold: 1, tracked_errors: [ anonymous ])
        c.register(:by_proc, threshold: 1, tracked_errors: [ ->(error) { error.message == "boom" } ])
      end

      trip(:anon, anonymous.new("x"))
      trip(:by_proc)

      expect(StandardCircuit.runner.light_for(:anon).color).to eq(Stoplight::Color::RED)
      expect(StandardCircuit.runner.light_for(:by_proc).color).to eq(Stoplight::Color::RED)
    end

    it "still skips errors outside the tracked list" do
      StandardCircuit.configure { |c| c.register(:narrow, threshold: 1, tracked_errors: [ IOError ]) }

      trip(:narrow)

      expect(StandardCircuit.runner.light_for(:narrow).color).to eq(Stoplight::Color::GREEN)
    end

    it "rounds fractional and sub-second durations up to whole seconds instead of raising" do
      StandardCircuit.configure do |c|
        c.register(:fractional, cool_off_time: 1.5, window_size: 59.5)
        c.register(:zero, cool_off_time: 0)
      end

      expect(StandardCircuit.run(:fractional) { :ok }).to eq(:ok)
      expect(StandardCircuit.run(:zero) { :ok }).to eq(:ok)
      expect(StandardCircuit.config.spec_for(:fractional).cool_off_time).to eq(1.5)
    end

    it "accepts a re-configure that changes a circuit's settings" do
      StandardCircuit.configure { |c| c.register(:again, threshold: 5) }
      StandardCircuit.run(:again) { :ok }

      StandardCircuit.configure { |c| c.register(:again, threshold: 1, tracked_errors: [ RuntimeError ]) }
      trip(:again)

      expect(StandardCircuit.runner.light_for(:again).color).to eq(Stoplight::Color::RED)
    end

    it "starts from fresh counters when a new Memory store is assigned after configure" do
      StandardCircuit.configure { |c| c.register(:swap, threshold: 1, tracked_errors: [ RuntimeError ]) }
      trip(:swap)
      expect(StandardCircuit.runner.light_for(:swap).color).to eq(Stoplight::Color::RED)

      StandardCircuit.config.data_store = Stoplight::DataStore::Memory.new

      expect(StandardCircuit.runner.light_for(:swap).color).to eq(Stoplight::Color::GREEN)
    end

    it "keeps its lights out of the host's global Stoplight registry" do
      StandardCircuit.configure { |c| c.register(:private_light) }
      StandardCircuit.run(:private_light) { :ok }

      expect { Stoplight.light("private_light") }.to raise_error(Stoplight::Error::UnregisteredLightError)
    end
  end
end
