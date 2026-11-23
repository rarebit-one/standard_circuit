require "spec_helper"

# Rolling stats through real runs, metrics_only, and dependency_report.
# `configure` wires the internal subscribers, including Stats::Subscriber.
RSpec.describe StandardCircuit::Dependency do
  def fail_once(name, purpose: nil)
    StandardCircuit.run(name, purpose: purpose) { raise "boom" }
  rescue RuntimeError, Stoplight::Error::RedLight
    nil
  end

  def dependency(name) = StandardCircuit.dependency(name)

  def capture(pattern)
    events = []
    callback = ->(name, _s, _f, _i, payload) { events << [ name, payload ] }
    ActiveSupport::Notifications.subscribed(callback, pattern) { yield }
    events
  end

  before do
    # One backend for the whole example: subscribe and emit on AS::Notifications.
    hide_const("Rails") if defined?(::Rails)
  end

  describe "stats" do
    before do
      StandardCircuit.configure do |c|
        c.stats_window_size = 50
        c.dependency :google_oauth, threshold: 10, tracked_errors: [ RuntimeError ] do |d|
          d.purpose :sign_in, criticality: :critical
          d.purpose :calendar, criticality: :standard
        end
        c.register_prefix(:s3)
      end
    end

    it "keeps a window per dependency and per purpose" do
      2.times { StandardCircuit.run(:google_oauth, purpose: :calendar) { :ok } }
      fail_once(:google_oauth, purpose: :calendar)

      expect(dependency(:google_oauth).stats).to include(calls: 3, window_size: 50, consecutive_failures: 1)
      expect(dependency(:google_oauth).purpose(:calendar).stats)
        .to include(calls: 3, counts: { success: 2, failure: 1, circuit_open: 0 })
      expect(dependency(:google_oauth).purpose(:sign_in).stats).to include(calls: 0, error_rate: nil)
    end

    it "records a prefix dependency's sub-circuits under the dependency" do
      StandardCircuit.run(:s3_uploads) { :ok }
      StandardCircuit.run(:s3_avatars) { :ok }

      expect(dependency(:s3).stats[:calls]).to eq(2)
      expect(dependency(:s3).purpose(:default).stats[:calls]).to eq(2)
    end

    it "counts circuit_open calls without counting them as failures" do
      dependency(:google_oauth).lock_open!
      fail_once(:google_oauth, purpose: :sign_in)

      expect(dependency(:google_oauth).purpose(:sign_in).stats)
        .to include(counts: { success: 0, failure: 0, circuit_open: 1 }, error_rate: nil)
    end

    it "never lets stats recording break the wrapped call" do
      allow(StandardCircuit.stats).to receive(:record).and_raise(RuntimeError, "store down")

      result = nil
      expect { result = StandardCircuit.run(:google_oauth, purpose: :sign_in) { :signed_in } }
        .to output(/stats recording failed/).to_stderr
      expect(result).to eq(:signed_in)
    end

    it "is cleared by reset!" do
      StandardCircuit.run(:google_oauth, purpose: :sign_in) { :ok }
      StandardCircuit.reset!

      expect(dependency(:google_oauth).stats[:calls]).to eq(0)
    end
  end

  describe "stats_window_size" do
    it "rejects anything but a positive Integer" do
      expect { StandardCircuit.config.stats_window_size = 0 }.to raise_error(ArgumentError)
      expect { StandardCircuit.config.stats_window_size = 10.5 }.to raise_error(ArgumentError)
    end

    it "defaults to Stats::DEFAULT_WINDOW_SIZE" do
      expect(StandardCircuit::Config.new.stats_window_size).to eq(StandardCircuit::Stats::DEFAULT_WINDOW_SIZE)
    end
  end

  describe "metrics_only" do
    before do
      StandardCircuit.configure do |c|
        c.dependency :new_api, criticality: :critical, threshold: 1, metrics_only: true,
                     tracked_errors: [ RuntimeError ]
        c.dependency :maps, threshold: 1, tracked_errors: [ RuntimeError ] do |d|
          d.purpose :places, default: true
          d.purpose :address, isolate: true, metrics_only: true
        end
      end
    end

    it "times and records calls but never opens" do
      events = capture(/\Astandard_circuit\./) { 5.times { fail_once(:new_api) } }

      expect(StandardCircuit.run(:new_api) { :still_called }).to eq(:still_called)
      expect(dependency(:new_api)).to have_attributes(open?: false, status: :ok, metrics_only?: true)
      expect(dependency(:new_api).stats).to include(counts: { success: 1, failure: 5, circuit_open: 0 })
      expect(events.map(&:first).uniq).to eq([ "standard_circuit.run.completed" ])
    end

    it "behaves like a closed breaker towards fallbacks" do
      expect(StandardCircuit.run(:new_api, fallback: ->(e) { e.message }) { raise "boom" }).to eq("boom")
      expect { StandardCircuit.run(:new_api, fallback: -> { :nope }) { raise IOError } }.to raise_error(IOError)
    end

    it "ignores forced states and locks" do
      dependency(:new_api).lock_open!

      StandardCircuit.force_open(:new_api) do
        expect(StandardCircuit.run(:new_api) { :called }).to eq(:called)
        expect(dependency(:new_api).open?).to be(false)
      end
    end

    it "can apply to one isolated purpose while the rest enforce" do
      fail_once(:maps, purpose: :address)
      fail_once(:maps, purpose: :places)

      expect(dependency(:maps).purpose(:address)).to have_attributes(metrics_only?: true, open?: false)
      expect(dependency(:maps).purpose(:places).open?).to be(true)
      expect(dependency(:maps).metrics_only?).to be(false)
    end

    it "needs isolate: true on a purpose" do
      expect {
        StandardCircuit.config.dependency(:x) { |d| d.purpose :a, metrics_only: true }
      }.to raise_error(ArgumentError, /isolate: true/)
    end

    it "keeps a metrics-only prefix's sub-circuits discoverable" do
      StandardCircuit.config.register_prefix(:s3, metrics_only: true, criticality: :standard)
      StandardCircuit.run(:s3_uploads) { :ok }

      expect(dependency(:s3).circuit_names).to eq([ :s3_uploads ])
      expect(StandardCircuit.health_report[:circuits]).to include(a_hash_including(name: :s3_uploads, color: "green"))
      expect(StandardCircuit.dependency_report.find { |r| r[:name] == :s3 }[:circuits].map { |c| c[:name] })
        .to eq([ :s3_uploads ])
    end

    it "works through register too" do
      StandardCircuit.config.register(:observed, threshold: 1, metrics_only: true, tracked_errors: [ RuntimeError ])
      3.times { fail_once(:observed) }

      expect(StandardCircuit.run(:observed) { :ok }).to eq(:ok)
    end
  end

  describe "StandardCircuit.dependency_report" do
    before do
      StandardCircuit.configure do |c|
        c.register(:stripe, threshold: 1, criticality: :critical, tracked_errors: [ RuntimeError ])
        c.dependency :google_oauth, threshold: 5 do |d|
          d.purpose :sign_in, criticality: :critical
          d.purpose :calendar, criticality: :standard
        end
      end
    end

    it "returns one row per dependency" do
      fail_once(:stripe)
      StandardCircuit.run(:google_oauth, purpose: :calendar) { :ok }

      report = StandardCircuit.dependency_report

      expect(report.map { |row| row.slice(:name, :status, :criticality, :open, :metrics_only) }).to eq([
        { name: :stripe, status: :unavailable, criticality: :critical, open: true, metrics_only: false },
        { name: :google_oauth, status: :ok, criticality: :critical, open: false, metrics_only: false }
      ])
    end

    it "shows each purpose with its criticality and stats, and each circuit" do
      StandardCircuit.run(:google_oauth, purpose: :calendar) { :ok }

      row = StandardCircuit.dependency_report.find { |r| r[:name] == :google_oauth }

      expect(row[:purposes].map { |p| [ p[:name], p[:criticality], p[:stats][:calls] ] })
        .to eq([ [ :sign_in, :critical, 0 ], [ :calendar, :standard, 1 ] ])
      expect(row[:purposes].first).to include(status: :ok, open: false, isolated: false, circuits: [ :google_oauth ])
      expect(row[:circuits]).to eq([ { name: :google_oauth, color: "green", locked: false, forced: nil } ])
    end

    it "reads each circuit's state once per row, so its fields describe one moment" do
      allow(StandardCircuit.runner).to receive(:circuit_state).and_call_original

      StandardCircuit.dependency(:google_oauth).report

      expect(StandardCircuit.runner).to have_received(:circuit_state).with(:google_oauth).once
    end

    it "leaves health_report as it was" do
      before_report = StandardCircuit.health_report
      StandardCircuit.dependency_report

      expect(StandardCircuit.health_report).to eq(before_report)
      expect(before_report.keys).to eq([ :status, :circuits ])
    end
  end
end
