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

  describe "#mailer_retry" do
    it "defaults to nil (off)" do
      expect(config.mailer_retry).to be_nil
    end

    it "expands true to the defaults" do
      config.mailer_retry = true
      expect(config.mailer_retry).to eq(wait: 90, attempts: 5, jitter: 0.15)
    end

    it "merges a partial Hash over the defaults, accepting string keys" do
      config.mailer_retry = { "attempts" => 8, wait: :polynomially_longer }
      expect(config.mailer_retry).to eq(wait: :polynomially_longer, attempts: 8, jitter: 0.15)
      expect(config.mailer_retry).to be_frozen
    end

    it "turns off with false" do
      config.mailer_retry = true
      config.mailer_retry = false
      expect(config.mailer_retry).to be_nil
    end

    it "rejects unknown keys" do
      expect { config.mailer_retry = { retries: 3 } }
        .to raise_error(ArgumentError, /unknown mailer_retry option\(s\) \[:retries\]/)
    end

    it "rejects other types" do
      expect { config.mailer_retry = 5 }.to raise_error(ArgumentError, /must be nil, true, false, or a Hash/)
    end
  end

  describe "#add_notifier idempotency (configure runs on every to_prepare)" do
    # Stand-in for a host notifier class. A code reload builds a new class
    # object with the same name, so we stub_const a fresh class per "reload".
    def reload_notifier_class
      stub_const("HostCircuitNotifier", Class.new { def call(_name, _payload) = nil })
    end

    it "replaces an instance of the same class instead of stacking a duplicate" do
      first = reload_notifier_class.new
      config.add_notifier(first)
      second = reload_notifier_class.new
      config.add_notifier(second)

      expect(config.extra_notifiers).to eq([ second ])
    end

    it "keeps the replacement in the original position" do
      config.add_notifier(reload_notifier_class.new)
      other = ->(_n, _p) { }
      config.add_notifier(other)
      replacement = reload_notifier_class.new
      config.add_notifier(replacement)

      expect(config.extra_notifiers).to eq([ replacement, other ])
    end

    it "dedupes a lambda re-created from the same source line" do
      2.times { config.add_notifier(->(_n, _p) { }) }
      expect(config.extra_notifiers.size).to eq(1)
    end

    it "keeps lambdas from different source lines" do
      config.add_notifier(->(_n, _p) { })
      config.add_notifier(->(_n, _p) { })
      expect(config.extra_notifiers.size).to eq(2)
    end

    it "dedupes a class used directly as the notifier" do
      klass = stub_const("ModuleNotifier", Module.new { def self.call(_n, _p) = nil })
      2.times { config.add_notifier(klass) }
      expect(config.extra_notifiers).to eq([ klass ])
    end

    it "keeps two instances of one class when given distinct keys" do
      klass = reload_notifier_class
      config.add_notifier(klass.new, key: :ops_webhook)
      config.add_notifier(klass.new, key: :audit_webhook)
      config.add_notifier(klass.new, key: :ops_webhook)

      expect(config.extra_notifiers.size).to eq(2)
    end

    it "never dedupes instances of anonymous classes" do
      klass = Class.new { def call(_n, _p) = nil }
      2.times { config.add_notifier(klass.new) }
      expect(config.extra_notifiers.size).to eq(2)
    end

    it "is forgotten by reset_registry!" do
      config.add_notifier(reload_notifier_class.new)
      config.reset_registry!
      config.add_notifier(reload_notifier_class.new)
      expect(config.extra_notifiers.size).to eq(1)
    end

    it "keeps StandardCircuit.configure from re-registering duplicate subscribers" do
      received = []
      notifier_class = stub_const("CountingNotifier", Class.new do
        define_method(:initialize) { |sink| @sink = sink }
        define_method(:call) { |name, _payload| @sink << name }
      end)
      3.times { StandardCircuit.configure { |c| c.add_notifier(notifier_class.new(received)) } }

      StandardCircuit::EventEmitter.emit("standard_circuit.circuit.opened", circuit: "x")
      expect(received).to eq([ "standard_circuit.circuit.opened" ])
    ensure
      StandardCircuit.config.reset_registry!
    end
  end
end
