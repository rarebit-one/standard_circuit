require "spec_helper"

RSpec.describe StandardCircuit::HealthRules do
  def rules_for(name) = StandardCircuit.config.dependency_spec(name).health_rules

  it "is off (nil) unless declared" do
    StandardCircuit.config.register(:stripe)

    expect(rules_for(:stripe)).to be_nil
  end

  it "defaults min_calls to 20" do
    StandardCircuit.config.register(:stripe, health: { error_rate: 0.25 })

    expect(rules_for(:stripe)).to have_attributes(error_rate: 0.25, slow_ms: nil, min_calls: 20)
  end

  it "is accepted by register, register_prefix, register_preset and dependency" do
    config = StandardCircuit.config
    config.register(:stripe, health: { error_rate: 0.5 })
    config.register_prefix(:s3, health: { slow_ms: 800 })
    config.register_preset(:postmark, health: { error_rate: 0.3, min_calls: 10 })
    config.dependency(:harness, health: { slow_ms: 2000 }) { |d| d.purpose :reply }

    expect([ :stripe, :s3, :postmark, :harness ].map { |name| rules_for(name).to_h.compact }).to eq([
      { error_rate: 0.5, min_calls: 20 }, { slow_ms: 800, min_calls: 20 },
      { error_rate: 0.3, min_calls: 10 }, { slow_ms: 2000, min_calls: 20 }
    ])
  end

  {
    { error_rate: 0 } => /error_rate .* \(0, 1\]/,
    { error_rate: 1.5 } => /error_rate .* \(0, 1\]/,
    { slow_ms: -1 } => /slow_ms .* positive number/,
    { min_calls: 0 } => /min_calls .* positive Integer/,
    { min_calls: 2.5 } => /min_calls .* positive Integer/,
    { p99_ms: 100 } => /unknown health: option\(s\) \[:p99_ms\]/
  }.each do |options, message|
    it "rejects #{options.inspect} at configure time" do
      expect { StandardCircuit.config.register(:stripe, health: options) }.to raise_error(ArgumentError, message)
    end
  end

  it "rejects a non-Hash" do
    expect { StandardCircuit.config.dependency(:stripe, health: 0.25) }.to raise_error(ArgumentError, /must be a Hash/)
  end

  it "leaves the registry untouched when a dependency's rules are rejected" do
    StandardCircuit.config.register(:stripe)

    expect { StandardCircuit.config.register(:stripe, health: { error_rate: 2 }) }.to raise_error(ArgumentError)
    expect(rules_for(:stripe)).to be_nil
  end
end
