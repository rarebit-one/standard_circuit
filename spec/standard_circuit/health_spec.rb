require "spec_helper"

RSpec.describe StandardCircuit::Health do
  # Trips a circuit once with a RuntimeError, swallowing the re-raise.
  def trip_once(name)
    StandardCircuit.run(name) { raise "boom" }
  rescue RuntimeError
    # expected — the circuit records a failure and re-raises
  end

  describe ".snapshot" do
    context "with an empty config" do
      before { StandardCircuit.configure { |_c| } }

      it "returns an empty array" do
        expect(StandardCircuit.health_snapshot).to eq([])
      end
    end

    context "with a green named circuit" do
      before do
        StandardCircuit.configure do |c|
          c.register(:stripe, threshold: 5, cool_off_time: 30, criticality: :critical)
        end
      end

      it "eagerly builds the light and reports color=green" do
        entry = StandardCircuit.health_snapshot.first
        expect(entry).to include(
          name: :stripe,
          color: "green",
          locked: false,
          criticality: :critical
        )
        expect(entry).not_to have_key(:cool_off_until)
      end
    end

    context "with a red (locked open) named circuit" do
      before do
        StandardCircuit.configure do |c|
          c.register(:sendgrid, threshold: 3, cool_off_time: 60, criticality: :standard)
        end
        StandardCircuit.runner.light_for(:sendgrid).lock(Stoplight::Color::RED)
      end

      it "reports color=red and locked=true with criticality passed through" do
        entry = StandardCircuit.health_snapshot.find { |e| e[:name] == :sendgrid }
        expect(entry).to include(
          name: :sendgrid,
          color: "red",
          locked: true,
          criticality: :standard
        )
      end
    end

    context "with a yellow (half-open) named circuit" do
      before do
        StandardCircuit.configure do |c|
          c.register(:slow_api, threshold: 1, cool_off_time: 0, criticality: :critical,
                     tracked_errors: [ RuntimeError ])
        end
        # Trip it once past the threshold so it goes RED with cool_off_time=0,
        # which lets it immediately fall into YELLOW on the next inspection.
        trip_once(:slow_api)
      end

      it "reports a non-green color reflecting actual state" do
        entry = StandardCircuit.health_snapshot.find { |e| e[:name] == :slow_api }
        expect(entry[:name]).to eq(:slow_api)
        expect(entry[:color]).to satisfy { |c| [ "yellow", "red" ].include?(c) }
        expect(entry[:locked]).to be(false)
        expect(entry[:criticality]).to eq(:critical)
      end
    end

    context "with multiple named circuits" do
      before do
        StandardCircuit.configure do |c|
          c.register(:a, criticality: :critical)
          c.register(:b, criticality: :standard)
          c.register(:c, criticality: :optional)
        end
      end

      it "includes one entry per registered circuit" do
        names = StandardCircuit.health_snapshot.map { |e| e[:name] }.sort
        expect(names).to eq([ :a, :b, :c ])
      end
    end

    context "with a prefix-exercised circuit" do
      before do
        StandardCircuit.configure do |c|
          c.register_prefix(:s3, threshold: 3, cool_off_time: 30, criticality: :standard,
                            tracked_errors: [ Net::ReadTimeout ])
        end
        # exercise the prefix so the runner caches a concrete light
        StandardCircuit.run(:s3_user_content) { :ok }
      end

      it "includes the exercised dynamic circuit in the snapshot" do
        entry = StandardCircuit.health_snapshot.find { |e| e[:name] == :s3_user_content }
        expect(entry).to include(
          name: :s3_user_content,
          color: "green",
          criticality: :standard
        )
      end
    end

    context "with an unexercised prefix" do
      before do
        StandardCircuit.configure do |c|
          c.register_prefix(:s3, threshold: 3, cool_off_time: 30, criticality: :standard)
        end
      end

      it "omits prefix-only circuits that have never been exercised" do
        # No dynamic :s3_* names have been touched; nothing to enumerate.
        expect(StandardCircuit.health_snapshot).to eq([])
      end
    end

    context "with both named and prefix-exercised circuits" do
      before do
        StandardCircuit.configure do |c|
          c.register(:stripe, criticality: :critical)
          c.register_prefix(:s3, criticality: :standard, tracked_errors: [ Net::ReadTimeout ])
        end
        StandardCircuit.run(:s3_bucket_one) { :ok }
      end

      it "surfaces both categories with their respective criticalities" do
        snapshot = StandardCircuit.health_snapshot
        names = snapshot.map { |e| e[:name] }
        expect(names).to include(:stripe, :s3_bucket_one)

        stripe = snapshot.find { |e| e[:name] == :stripe }
        bucket = snapshot.find { |e| e[:name] == :s3_bucket_one }
        expect(stripe[:criticality]).to eq(:critical)
        expect(bucket[:criticality]).to eq(:standard)
      end
    end
  end

  describe ".overall" do
    it "returns :ok when no entries are present" do
      StandardCircuit.configure { |_c| }
      expect(StandardCircuit.health_overall).to eq(:ok)
    end

    it "returns :ok when every circuit is green" do
      StandardCircuit.configure do |c|
        c.register(:a, criticality: :critical)
        c.register(:b, criticality: :standard)
      end
      expect(StandardCircuit.health_overall).to eq(:ok)
    end

    it "returns :critical when any :critical circuit is red" do
      StandardCircuit.configure do |c|
        c.register(:payments, criticality: :critical)
        c.register(:emails, criticality: :standard)
      end
      StandardCircuit.runner.light_for(:payments).lock(Stoplight::Color::RED)
      expect(StandardCircuit.health_overall).to eq(:critical)
    end

    it "returns :degraded when a :standard circuit is red but no :critical is red" do
      StandardCircuit.configure do |c|
        c.register(:payments, criticality: :critical)
        c.register(:emails, criticality: :standard)
      end
      StandardCircuit.runner.light_for(:emails).lock(Stoplight::Color::RED)
      expect(StandardCircuit.health_overall).to eq(:degraded)
    end

    it "returns :ok when only an :optional circuit is red" do
      StandardCircuit.configure do |c|
        c.register(:payments, criticality: :critical)
        c.register(:nice_to_have, criticality: :optional)
      end
      StandardCircuit.runner.light_for(:nice_to_have).lock(Stoplight::Color::RED)
      expect(StandardCircuit.health_overall).to eq(:ok)
    end

    it "prefers :critical over :degraded when both conditions are met" do
      StandardCircuit.configure do |c|
        c.register(:payments, criticality: :critical)
        c.register(:emails, criticality: :standard)
      end
      StandardCircuit.runner.light_for(:payments).lock(Stoplight::Color::RED)
      StandardCircuit.runner.light_for(:emails).lock(Stoplight::Color::RED)
      expect(StandardCircuit.health_overall).to eq(:critical)
    end

    it "derives overall status from color for a tripped :critical circuit" do
      StandardCircuit.configure do |c|
        c.register(:llm, threshold: 1, cool_off_time: 0, criticality: :critical,
                   tracked_errors: [ RuntimeError ])
      end
      trip_once(:llm)

      color = StandardCircuit.health_snapshot.first[:color]
      expected = { "yellow" => :degraded, "red" => :critical }.fetch(color, :ok)
      expect(StandardCircuit.health_overall).to eq(expected)
    end
  end
end
