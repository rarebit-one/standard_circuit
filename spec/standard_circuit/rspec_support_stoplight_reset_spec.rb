require "spec_helper"
require "standard_circuit/rspec"

# The standard_circuit/rspec helper frees the stoplight systems earlier
# examples left behind with stoplight's own test reset, and only there:
# StandardCircuit.reset! itself stays on the public API and moves to the next
# generation. Without that reset the helper falls back to generations.
RSpec.describe StandardCircuit::RSpecSupport do
  def runner = StandardCircuit.runner

  def configure_and_use
    StandardCircuit.configure { |c| c.register(:svc, threshold: 1, tracked_errors: [ RuntimeError ]) }
    StandardCircuit.run(:svc) { :ok }
  end

  def trip
    StandardCircuit.run(:svc) { raise "boom" }
  rescue RuntimeError, Stoplight::Error::RedLight
    nil
  end

  before do
    hide_const("Rails") if defined?(::Rails)
    described_class.instance_variable_set(:@warned_missing_reset, nil)
  end

  after { described_class.instance_variable_set(:@warned_missing_reset, nil) }

  describe "with stoplight's test reset available" do
    it "brings the runner back on standard_circuit, however many generations came before" do
      configure_and_use
      3.times do
        StandardCircuit.reset!
        StandardCircuit.run(:svc) { :ok }
      end
      expect(runner.system_name).not_to eq(StandardCircuit::Runner::SYSTEM_NAME)

      described_class.reset_between_examples!
      configure_and_use

      expect(runner.system_name).to eq(StandardCircuit::Runner::SYSTEM_NAME)
    end

    it "keeps generation numbers from growing from one example to the next" do
      names = Array.new(5) do
        described_class.reset_between_examples!
        configure_and_use
        trip
        runner.system_name
      end

      expect(names).to eq([ StandardCircuit::Runner::SYSTEM_NAME ] * 5)
    end

    it "leaves every circuit green with zero failures" do
      configure_and_use
      trip
      expect(runner.light_for(:svc).color).to eq(Stoplight::Color::RED)

      described_class.reset_between_examples!

      expect(runner.light_for(:svc).color).to eq(Stoplight::Color::GREEN)
      expect(StandardCircuit.run(:svc) { :ok }).to eq(:ok)
    end

    it "clears circuits a host registered with Stoplight directly, too" do
      Stoplight.register("host_light")

      described_class.reset_between_examples!

      expect { Stoplight.light("host_light") }.to raise_error(Stoplight::Error::UnregisteredLightError)
    end
  end

  describe "StandardCircuit.reset! on its own" do
    it "never calls stoplight's test reset and moves to the next generation" do
      allow(Stoplight).to receive(:__stoplight__reset!).and_call_original
      configure_and_use
      before_reset = runner.system_name

      StandardCircuit.reset!
      StandardCircuit.run(:svc) { :ok }

      expect(runner.system_name).not_to eq(before_reset)
      expect(Stoplight).not_to have_received(:__stoplight__reset!)
    end
  end

  describe "without stoplight's test reset" do
    before do
      allow(Stoplight).to receive(:respond_to?).and_call_original
      allow(Stoplight).to receive(:respond_to?).with(:__stoplight__reset!).and_return(false)
      allow(Stoplight).to receive(:__stoplight__reset!)
      allow(described_class).to receive(:warn)
    end

    it "falls back to generations without raising, and still resets breaker state" do
      configure_and_use
      trip
      before_reset = runner.system_name

      described_class.reset_between_examples!

      expect(runner.light_for(:svc).color).to eq(Stoplight::Color::GREEN)
      expect(runner.system_name).not_to eq(before_reset)
      expect(Stoplight).not_to have_received(:__stoplight__reset!)
    end

    it "warns once per process, not once per example" do
      3.times do
        described_class.reset_between_examples!
        configure_and_use
      end

      expect(described_class).to have_received(:warn).once
    end
  end
end
