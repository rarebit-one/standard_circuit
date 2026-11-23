require "spec_helper"

# Covers Config#dependency, the register/register_prefix shims, run(purpose:)
# and the read side of StandardCircuit.dependency.
RSpec.describe StandardCircuit::Dependency do
  def fail_once(name, purpose: nil)
    StandardCircuit.run(name, purpose: purpose) { raise "boom" }
  rescue RuntimeError
    nil
  end

  def color(circuit)
    StandardCircuit.runner.light_for(circuit).color
  end

  def capture_run_completed
    events = []
    callback = ->(_name, _s, _f, _i, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(callback, "standard_circuit.run.completed") do
      hide_const("Rails") if defined?(::Rails)
      yield
    end
    events
  end

  describe "old-style registrations" do
    before do
      StandardCircuit.configure do |c|
        c.register(:stripe, threshold: 5, criticality: :critical)
        c.register_prefix(:s3, criticality: :standard)
        c.register_preset(:postmark)
      end
    end

    it "are dependencies with one implicit :default purpose" do
      stripe = StandardCircuit.dependency(:stripe)

      expect(stripe).to have_attributes(name: :stripe, criticality: :critical, circuit_names: [ :stripe ])
      expect(stripe.purposes.map(&:name)).to eq([ :default ])
      expect(stripe.purpose(:default)).to have_attributes(criticality: :critical, circuit_name: :stripe, default?: true)
      expect(StandardCircuit.dependency(:postmark).circuit_names).to eq([ :postmark ])
    end

    it "show a prefix registration's circuits as sub-circuits of one dependency" do
      s3 = StandardCircuit.dependency(:s3)
      expect(s3).to be_prefix
      expect(s3.circuit_names).to eq([])

      StandardCircuit.run(:s3_uploads) { :ok }
      StandardCircuit.run(:s3_avatars) { :ok }

      expect(s3.circuit_names).to contain_exactly(:s3_uploads, :s3_avatars)
    end

    it "lists every dependency" do
      expect(StandardCircuit.dependencies.map(&:name)).to eq([ :stripe, :postmark, :s3 ])
    end

    it "tag run.completed with the dependency and its implicit purpose" do
      events = capture_run_completed do
        StandardCircuit.run(:stripe) { :ok }
        StandardCircuit.run(:s3_uploads) { :ok }
      end

      expect(events.map { |e| e.slice(:circuit, :dependency, :purpose, :criticality) }).to eq([
        { circuit: "stripe", dependency: :stripe, purpose: :default, criticality: :critical },
        { circuit: "s3_uploads", dependency: :s3, purpose: :default, criticality: :standard }
      ])
    end

    it "keep circuits in declaration order when re-registered" do
      StandardCircuit.config.register(:stripe, threshold: 2, criticality: :critical)

      expect(StandardCircuit.config.circuits.keys).to eq([ :stripe, :postmark ])
    end
  end

  # The report standard_health reads must not move by a byte for a config
  # that only uses the 0.6 API.
  describe "health_report for an old-style config" do
    before do
      StandardCircuit.configure do |c|
        c.register(:stripe, threshold: 1, criticality: :critical, tracked_errors: [ RuntimeError ])
        c.register(:mailer, criticality: :standard)
        c.register_prefix(:s3, criticality: :optional)
      end
      fail_once(:stripe)
      StandardCircuit.runner.light_for(:mailer).lock(Stoplight::Color::RED)
      StandardCircuit.run(:s3_uploads) { :ok }
    end

    it "is unchanged" do
      expect(StandardCircuit.health_report).to eq(
        status: :critical,
        circuits: [
          { name: :stripe, color: "red", locked: false, criticality: :critical },
          { name: :mailer, color: "red", locked: true, criticality: :standard },
          { name: :s3_uploads, color: "green", locked: false, criticality: :optional }
        ]
      )
    end

    it "serializes to the same bytes" do
      expect(StandardCircuit.health_report.to_json).to eq(
        '{"status":"critical","circuits":[' \
        '{"name":"stripe","color":"red","locked":false,"criticality":"critical"},' \
        '{"name":"mailer","color":"red","locked":true,"criticality":"standard"},' \
        '{"name":"s3_uploads","color":"green","locked":false,"criticality":"optional"}]}'
      )
    end
  end

  describe "a dependency without declared purposes" do
    before do
      StandardCircuit.configure do |c|
        c.dependency :stripe, criticality: :critical, threshold: 2, tracked_errors: [ RuntimeError ]
      end
    end

    it "runs without a purpose through its implicit :default purpose" do
      expect(StandardCircuit.run(:stripe) { :charged }).to eq(:charged)
      expect(StandardCircuit.run(:stripe, purpose: :default) { :charged }).to eq(:charged)
    end

    it "registers one breaker named after the dependency" do
      expect(StandardCircuit.config.circuits.keys).to eq([ :stripe ])
      expect(StandardCircuit.config.spec_for(:stripe)).to have_attributes(threshold: 2, criticality: :critical)
    end
  end

  describe "a dependency with purposes sharing its breaker" do
    before do
      StandardCircuit.configure do |c|
        c.dependency :google_oauth, threshold: 2, tracked_errors: [ RuntimeError ] do |d|
          d.purpose :sign_in, criticality: :critical
          d.purpose :calendar, criticality: :standard
        end
      end
    end

    it "trips the breaker for every purpose" do
      2.times { fail_once(:google_oauth, purpose: :calendar) }

      expect { StandardCircuit.run(:google_oauth, purpose: :sign_in) { :ok } }
        .to raise_error(Stoplight::Error::RedLight)
    end

    it "gives the shared breaker the worst purpose criticality" do
      expect(StandardCircuit.config.circuits.keys).to eq([ :google_oauth ])
      expect(StandardCircuit.config.spec_for(:google_oauth).criticality).to eq(:critical)
      expect(StandardCircuit.dependency(:google_oauth).criticality).to eq(:critical)
    end

    it "reports each call with its purpose's criticality" do
      events = capture_run_completed do
        StandardCircuit.run(:google_oauth, purpose: :calendar) { :ok }
        StandardCircuit.run(:google_oauth, purpose: :sign_in) { :ok }
      end

      expect(events.map { |e| e.slice(:circuit, :purpose, :criticality) }).to eq([
        { circuit: "google_oauth", purpose: :calendar, criticality: :standard },
        { circuit: "google_oauth", purpose: :sign_in, criticality: :critical }
      ])
    end

    it "raises PurposeRequired for a run without a purpose" do
      expect { StandardCircuit.run(:google_oauth) { :ok } }
        .to raise_error(StandardCircuit::PurposeRequired, /:sign_in, :calendar/)
    end

    it "raises UnknownPurpose for an undeclared purpose" do
      expect { StandardCircuit.run(:google_oauth, purpose: :drive) { :ok } }
        .to raise_error(StandardCircuit::UnknownPurpose, /no purpose :drive/)
      expect { StandardCircuit.dependency(:google_oauth).purpose(:drive) }
        .to raise_error(StandardCircuit::UnknownPurpose)
    end

    it "shares forced state across purposes, keyed by the breaker" do
      StandardCircuit.force_open(:google_oauth) do
        expect { StandardCircuit.run(:google_oauth, purpose: :calendar) { :ok } }
          .to raise_error(Stoplight::Error::RedLight)
      end
    end
  end

  describe "a purpose marked default" do
    it "serves runs without a purpose" do
      StandardCircuit.configure do |c|
        c.dependency :google_maps, criticality: :optional do |d|
          d.purpose :places, default: true
          d.purpose :address
        end
      end

      events = capture_run_completed { StandardCircuit.run(:google_maps) { :ok } }

      expect(events.first).to include(purpose: :places, criticality: :optional)
    end
  end

  describe "an isolated purpose" do
    before do
      StandardCircuit.configure do |c|
        c.dependency :google_maps, criticality: :optional, threshold: 5, cool_off_time: 45,
                     tracked_errors: [ RuntimeError ] do |d|
          d.purpose :places
          d.purpose :address, isolate: true, threshold: 1, criticality: :standard
        end
      end
    end

    it "gets its own breaker, named <dependency>_<purpose>, inheriting unset options" do
      expect(StandardCircuit.config.circuits.keys).to eq([ :google_maps, :google_maps_address ])
      expect(StandardCircuit.config.spec_for(:google_maps_address))
        .to have_attributes(threshold: 1, cool_off_time: 45, criticality: :standard, tracked_errors: [ RuntimeError ])
      expect(StandardCircuit.dependency(:google_maps).purpose(:address))
        .to have_attributes(isolated?: true, circuit_name: :google_maps_address)
    end

    it "trips without affecting the shared breaker" do
      fail_once(:google_maps, purpose: :address)

      expect(color(:google_maps_address)).to eq(Stoplight::Color::RED)
      expect(StandardCircuit.run(:google_maps, purpose: :places) { :ok }).to eq(:ok)
    end

    it "can be run by its breaker name, which keeps a hand-split circuit's call sites working" do
      events = capture_run_completed { StandardCircuit.run(:google_maps_address) { :ok } }

      expect(events.first).to include(circuit: "google_maps_address", dependency: :google_maps, purpose: :address)
      expect { StandardCircuit.run(:google_maps_address, purpose: :places) { :ok } }
        .to raise_error(StandardCircuit::UnknownPurpose)
    end

    it "appears in health_report as its own circuit" do
      names = StandardCircuit.health_report[:circuits].map { |e| e.slice(:name, :criticality) }

      expect(names).to eq([
        { name: :google_maps, criticality: :optional },
        { name: :google_maps_address, criticality: :standard }
      ])
    end
  end

  describe "when every purpose is isolated" do
    it "registers no shared breaker" do
      StandardCircuit.configure do |c|
        c.dependency :llm do |d|
          d.purpose :chat, isolate: true
          d.purpose :output_filter, isolate: true
        end
      end

      expect(StandardCircuit.config.circuits.keys).to eq([ :llm_chat, :llm_output_filter ])
    end
  end

  describe "re-declaring a dependency" do
    it "replaces its breakers, dropping ones it no longer declares" do
      StandardCircuit.configure do |c|
        c.dependency(:maps) { |d| d.purpose :address, isolate: true }
      end
      StandardCircuit.configure do |c|
        c.dependency(:maps) { |d| d.purpose :geocode, isolate: true }
      end

      expect(StandardCircuit.config.circuits.keys).to eq([ :maps_geocode ])
      expect { StandardCircuit.run(:maps_address) { :ok } }.to raise_error(StandardCircuit::UnknownCircuit)
    end

    it "lets register replace a dependency of the same name" do
      StandardCircuit.config.dependency(:maps) { |d| d.purpose :address, isolate: true }
      StandardCircuit.config.register(:maps)

      expect(StandardCircuit.config.circuits.keys).to eq([ :maps ])
      expect(StandardCircuit.dependency(:maps).purposes.map(&:name)).to eq([ :default ])
    end
  end

  describe "definition errors" do
    def define(&block)
      StandardCircuit.config.dependency(:dep, &block)
    end

    it "rejects a breaker name another dependency owns" do
      StandardCircuit.config.register(:google_maps_address)

      expect {
        StandardCircuit.config.dependency(:google_maps) { |d| d.purpose :address, isolate: true }
      }.to raise_error(ArgumentError, /already registered by dependency :google_maps_address/)
    end

    it "leaves the registry untouched when a re-declaration is rejected" do
      StandardCircuit.config.dependency(:maps) { |d| d.purpose :address, isolate: true }
      StandardCircuit.config.register(:maps_geocode)

      expect {
        StandardCircuit.config.dependency(:maps) { |d| d.purpose :geocode, isolate: true }
      }.to raise_error(ArgumentError, /already registered by dependency :maps_geocode/)
      expect(StandardCircuit.config.circuits.keys).to eq([ :maps_address, :maps_geocode ])
      expect(StandardCircuit.run(:maps, purpose: :address) { :ok }).to eq(:ok)
    end

    it "rejects a breaker named after another dependency" do
      StandardCircuit.config.dependency(:maps_address) { |d| d.purpose :lookup, isolate: true }

      expect {
        StandardCircuit.config.dependency(:maps) { |d| d.purpose :address, isolate: true }
      }.to raise_error(ArgumentError, /already registered by dependency :maps_address/)
    end

    it "rejects a dependency named after another dependency's breaker" do
      StandardCircuit.config.dependency(:maps) { |d| d.purpose :address, isolate: true }

      expect {
        StandardCircuit.config.dependency(:maps_address) { |d| d.purpose :lookup, isolate: true }
      }.to raise_error(ArgumentError, /name of a circuit already registered by dependency :maps/)
    end

    it "rejects breaker options on a purpose that shares the breaker" do
      expect { define { |d| d.purpose :a, threshold: 2 } }.to raise_error(ArgumentError, /isolate: true/)
    end

    it "rejects a purpose declared twice" do
      expect { define { |d| d.purpose(:a) && d.purpose(:a) } }.to raise_error(ArgumentError, /declared twice/)
    end

    it "rejects two default purposes" do
      expect { define { |d| d.purpose(:a, default: true) && d.purpose(:b, default: true) } }
        .to raise_error(ArgumentError, /already is/)
    end

    it "rejects an invalid criticality on the dependency or a purpose" do
      expect { StandardCircuit.config.dependency(:dep, criticality: :urgent) }.to raise_error(ArgumentError, /criticality/)
      expect { define { |d| d.purpose :a, criticality: :urgent } }.to raise_error(ArgumentError, /criticality/)
    end

    it "rejects unknown options" do
      expect { StandardCircuit.config.dependency(:dep, retries: 3) }.to raise_error(ArgumentError, /retries/)
    end
  end

  describe "lookups" do
    it "raises UnknownDependency, an UnknownCircuit, for an unknown name" do
      expect { StandardCircuit.dependency(:nope) }.to raise_error(StandardCircuit::UnknownDependency)
      expect(StandardCircuit::UnknownDependency.ancestors).to include(StandardCircuit::UnknownCircuit)
    end

    it "raises UnknownCircuit for a purpose on an unknown name" do
      expect { StandardCircuit.run(:nope, purpose: :x) { :ok } }.to raise_error(StandardCircuit::UnknownCircuit)
    end

    it "still allows forcing a name that was never registered" do
      StandardCircuit.force_closed(:never_registered) do
        expect(StandardCircuit.run(:never_registered) { :ran }).to eq(:ran)
      end
    end

    it "emits circuit.registered for each breaker a dependency declares" do
      events = []
      callback = ->(_name, _s, _f, _i, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, "standard_circuit.circuit.registered") do
        hide_const("Rails") if defined?(::Rails)
        StandardCircuit.config.dependency(:maps, criticality: :optional) { |d| d.purpose(:a) && d.purpose(:b, isolate: true) }
      end

      expect(events).to eq([
        { circuit: "maps", criticality: :optional, scope: :name },
        { circuit: "maps_b", criticality: :optional, scope: :name }
      ])
    end
  end
end
