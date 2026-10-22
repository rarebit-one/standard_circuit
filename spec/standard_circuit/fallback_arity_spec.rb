require "spec_helper"

# A fallback is called with the error (or nil when forced open). Hosts write
# "return this instead" as a zero-argument lambda, which would raise
# ArgumentError on that call at exactly the moment the circuit opens.
RSpec.describe StandardCircuit, ".run fallbacks of any arity" do
  before do
    hide_const("Rails") if defined?(::Rails)
    described_class.configure do |c|
      c.register(:flaky, threshold: 1, cool_off_time: 10, tracked_errors: [ RuntimeError ])
    end
  end

  def trip!
    StandardCircuit.run(:flaky) { raise "boom" }
  rescue RuntimeError
    nil
  end

  {
    "a zero-argument lambda" => -> { :fallback },
    "a lambda taking the error" => ->(_error) { :fallback },
    "a proc" => proc { :fallback }
  }.each do |label, fallback|
    it "returns #{label}'s value when the circuit has tripped" do
      trip!

      expect(described_class.run(:flaky, fallback: fallback) { :block }).to eq(:fallback)
    end

    it "returns #{label}'s value when forced open" do
      result = described_class.force_open(:flaky) do
        described_class.run(:flaky, fallback: fallback) { :block }
      end

      expect(result).to eq(:fallback)
    end
  end

  it "still passes the error to a fallback that takes it" do
    received = :unset
    described_class.force_open(:flaky) do
      described_class.run(:flaky, fallback: ->(error) { received = error }) { :block }
    end

    expect(received).to be_nil
  end

  it "runs the block, not the fallback, while the circuit is closed" do
    expect(described_class.run(:flaky, fallback: -> { :fallback }) { :block }).to eq(:block)
  end
end
