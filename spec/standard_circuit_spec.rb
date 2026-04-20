require "spec_helper"

RSpec.describe StandardCircuit do
  describe ".configure" do
    it "yields the config and returns it" do
      result = described_class.configure do |c|
        c.register(:example, threshold: 2, cool_off_time: 10)
      end

      expect(result).to be_a(StandardCircuit::Config)
      expect(result.spec_for(:example).threshold).to eq(2)
    end
  end

  describe ".run" do
    before do
      described_class.configure do |c|
        c.register(:http, threshold: 2, cool_off_time: 10,
                   tracked_errors: [ Net::OpenTimeout ])
      end
    end

    it "returns the block value on the happy path" do
      expect(described_class.run(:http) { :ok }).to eq(:ok)
    end

    it "raises UnknownCircuit when the circuit is not registered" do
      expect { described_class.run(:unknown) { :ok } }
        .to raise_error(StandardCircuit::UnknownCircuit)
    end

    it "propagates non-tracked exceptions unchanged" do
      expect { described_class.run(:http) { raise ArgumentError, "bug" } }
        .to raise_error(ArgumentError, "bug")
    end

    context "with a prefix registration" do
      before do
        described_class.configure do |c|
          c.register_prefix(:s3, threshold: 3, cool_off_time: 30,
                            tracked_errors: [ Net::ReadTimeout ])
        end
      end

      it "matches a dynamic name against the registered prefix" do
        expect(described_class.run(:s3_user_content) { :uploaded }).to eq(:uploaded)
      end
    end
  end

  describe ".force_open" do
    before do
      described_class.configure do |c|
        c.register(:stripe, threshold: 5, cool_off_time: 30)
      end
    end

    it "raises RedLight when forced open without a fallback" do
      described_class.force_open(:stripe)

      expect { described_class.run(:stripe) { :never_called } }
        .to raise_error(Stoplight::Error::RedLight)
    end

    it "calls the fallback when forced open" do
      described_class.force_open(:stripe)

      result = described_class.run(:stripe, fallback: ->(_e) { :fallback }) { :never_called }
      expect(result).to eq(:fallback)
    end

    it "scopes force state to the block form" do
      described_class.force_open(:stripe) do
        expect { described_class.run(:stripe) { :never_called } }
          .to raise_error(Stoplight::Error::RedLight)
      end

      expect(described_class.run(:stripe) { :ok }).to eq(:ok)
    end

    it "restores prior force state after a block" do
      described_class.force_closed(:stripe)
      described_class.force_open(:stripe) do
        expect { described_class.run(:stripe) { :never_called } }
          .to raise_error(Stoplight::Error::RedLight)
      end

      # after block exits, force_closed should be back in effect — block runs regardless of circuit state
      expect(described_class.run(:stripe) { :still_closed }).to eq(:still_closed)
    end
  end

  describe ".force_closed" do
    before do
      described_class.configure do |c|
        c.register(:lock, threshold: 1, cool_off_time: 10,
                   tracked_errors: [ Net::OpenTimeout ])
      end
    end

    it "yields the block without touching the light" do
      described_class.force_closed(:lock)
      expect(described_class.run(:lock) { :ok }).to eq(:ok)
    end
  end

  describe "#light_for cache atomicity (§8 precondition)" do
    before do
      described_class.configure do |c|
        c.register(:parallel, threshold: 3, cool_off_time: 10)
      end
    end

    it "builds exactly one Light under concurrent access" do
      runner = described_class.runner
      call_count = Concurrent::AtomicFixnum.new(0)
      original_build = runner.method(:build_light)

      allow(runner).to receive(:build_light) do |name|
        call_count.increment
        original_build.call(name)
      end

      futures = Array.new(100) { Concurrent::Future.execute { runner.light_for(:parallel) } }
      lights = futures.map(&:value!)

      expect(call_count.value).to eq(1)
      expect(lights.uniq.size).to eq(1)
    end
  end
end
