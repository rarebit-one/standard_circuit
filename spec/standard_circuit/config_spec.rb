require "spec_helper"

RSpec.describe StandardCircuit::Config do
  subject(:config) { described_class.new }

  describe "#sentry_criticality_levels" do
    it "defaults to nil so the Sentry subscriber stays in flat :warning mode" do
      expect(config.sentry_criticality_levels).to be_nil
    end

    it "resolves true to the recommended criticality map" do
      config.sentry_criticality_levels = true

      expect(config.sentry_criticality_levels)
        .to eq(StandardCircuit::Notifiers::Sentry::DEFAULT_LEVELS)
    end

    it "resolves false and nil back to flat mode" do
      config.sentry_criticality_levels = true
      config.sentry_criticality_levels = false
      expect(config.sentry_criticality_levels).to be_nil

      config.sentry_criticality_levels = true
      config.sentry_criticality_levels = nil
      expect(config.sentry_criticality_levels).to be_nil
    end

    it "merges a partial Hash over the recommended map" do
      config.sentry_criticality_levels = { optional: :debug }

      expect(config.sentry_criticality_levels)
        .to eq(critical: :error, standard: :warning, optional: :debug)
    end

    it "coerces String keys and values to Symbols" do
      config.sentry_criticality_levels = { "critical" => "fatal" }

      expect(config.sentry_criticality_levels).to include(critical: :fatal)
    end

    it "returns a frozen map so callers can't mutate shared config" do
      config.sentry_criticality_levels = { optional: :debug }

      expect(config.sentry_criticality_levels).to be_frozen
    end

    it "rejects an unknown criticality key" do
      expect { config.sentry_criticality_levels = { catastrophic: :fatal } }
        .to raise_error(ArgumentError, /invalid criticality :catastrophic/)
    end

    it "rejects a non-symbolizable criticality key as ArgumentError, not NoMethodError" do
      expect { config.sentry_criticality_levels = { 42 => :error } }
        .to raise_error(ArgumentError, /invalid criticality 42/)
    end

    it "rejects a level that isn't symbolizable" do
      expect { config.sentry_criticality_levels = { critical: 42 } }
        .to raise_error(ArgumentError, /invalid Sentry level 42/)
    end

    it "rejects a value that is neither a boolean, nil, nor a Hash" do
      expect { config.sentry_criticality_levels = :error }
        .to raise_error(ArgumentError, /must be nil, true, false, or a Hash/)
    end
  end
end
