require "spec_helper"
require "json"

RSpec.describe StandardCircuit::HealthRow do
  let(:now) { Time.utc(2026, 11, 25, 1, 0, 0) }

  def row(name) = StandardCircuit.dependency(name).health_row

  # Feed the rolling stats directly: the subscriber path is covered in
  # stats_spec, and this keeps each example to the rule it is about.
  def record(dependency, purpose, status, duration_ms = 10.0, times: 1, fallback_used: false)
    times.times { StandardCircuit.stats.record(dependency, purpose, status, duration_ms, fallback_used) }
  end

  # A dependency whose circuits report +color+ (half-open can't be reached
  # without waiting out a cool-off).
  def row_with_color(name, color)
    dependency = StandardCircuit.dependency(name)
    states = dependency.circuits.map { |state| state.merge(color: color) }
    allow(dependency).to receive(:circuits).and_return(states)
    dependency.health_row
  end

  describe "shape" do
    before do
      StandardCircuit.configure do |c|
        c.register(:stripe, criticality: :critical)
      end
    end

    it "carries the design-doc keys and exactly four measurements" do
      record(:stripe, :default, :success, 120.0, times: 3)
      record(:stripe, :default, :failure, 300.0, fallback_used: true)
      allow(StandardCircuit.stats).to receive(:for_dependency).and_wrap_original do |original, *args|
        original.call(*args).merge(last_success_at: now)
      end

      expect(row(:stripe)).to eq(
        name: "stripe", status: :ok, criticality: :critical,
        affected_purposes: [], reasons: [], metrics_only: false,
        circuits: [ { name: "stripe", color: "green", locked: false } ],
        measurements: { "stripe:errorRate" => 0.25, "stripe:p95Ms" => 300.0,
                        "stripe:lastSuccessAt" => "2026-11-25T01:00:00Z", "stripe:fallbackRate" => 0.25 }
      )
    end

    it "reports no evidence as nil measurements, never as healthy numbers" do
      expect(row(:stripe)[:measurements]).to eq(
        "stripe:errorRate" => nil, "stripe:p95Ms" => nil, "stripe:lastSuccessAt" => nil, "stripe:fallbackRate" => nil
      )
    end

    it "serialises to JSON" do
      expect(JSON.parse(row(:stripe).to_json)).to include("name" => "stripe", "status" => "ok", "criticality" => "critical")
    end
  end

  describe "status table" do
    before do
      StandardCircuit.configure do |c|
        [ :critical, :standard, :optional ].each do |criticality|
          c.register(:"#{criticality}_svc", criticality: criticality)
        end
      end
    end

    {
      [ "red", :critical ] => :unavailable, [ "red", :standard ] => :degraded, [ "red", :optional ] => :ok,
      [ "yellow", :critical ] => :degraded, [ "yellow", :standard ] => :degraded, [ "yellow", :optional ] => :ok,
      [ "green", :critical ] => :ok, [ "green", :standard ] => :ok, [ "green", :optional ] => :ok
    }.each do |(color, criticality), status|
      it "is #{status} for a #{criticality} dependency whose breaker is #{color}" do
        expect(row_with_color(:"#{criticality}_svc", color)[:status]).to eq(status)
      end
    end

    it "lists the purpose and the reason even when the finding costs nothing" do
      expect(row_with_color(:optional_svc, "red")).to include(
        status: :ok, affected_purposes: [ "default" ], reasons: [ "open" ]
      )
    end

    it "treats a forced-open breaker as open, and shows it red" do
      StandardCircuit.force_open(:critical_svc) do
        expect(row(:critical_svc)).to include(status: :unavailable, reasons: [ "open" ],
          circuits: [ { name: "critical_svc", color: "red", locked: false } ])
      end
    end

    it "treats a breaker locked open as open" do
      StandardCircuit.dependency(:standard_svc).lock_open!

      expect(row(:standard_svc)).to include(status: :degraded, reasons: [ "open" ],
        circuits: [ { name: "standard_svc", color: "red", locked: true } ])
    end
  end

  describe "purposes" do
    before do
      StandardCircuit.configure do |c|
        c.dependency :google_oauth do |d|
          d.purpose :sign_in, criticality: :critical
          d.purpose :calendar, criticality: :standard, isolate: true
        end
      end
    end

    it "takes the worst affected purpose: an isolated standard purpose's open breaker only degrades" do
      StandardCircuit.dependency(:google_oauth).purpose(:calendar).lock_open!

      expect(row(:google_oauth)).to include(status: :degraded, criticality: :critical,
        affected_purposes: [ "calendar" ], reasons: [ "open" ])
    end

    it "is unavailable when the critical purpose's breaker is open" do
      StandardCircuit.dependency(:google_oauth).purpose(:sign_in).lock_open!

      expect(row(:google_oauth)).to include(status: :unavailable, affected_purposes: [ "sign_in" ])
    end
  end

  describe "health rules (opt-in)" do
    it "never judges stats when the dependency declares no rules" do
      StandardCircuit.configure { |c| c.register(:stripe, criticality: :critical) }
      record(:stripe, :default, :failure, 9_000.0, times: 50)

      expect(row(:stripe)).to include(status: :ok, reasons: [])
    end

    context "with an error-rate rule" do
      before do
        StandardCircuit.configure do |c|
          c.register(:stripe, criticality: :critical, health: { error_rate: 0.25, min_calls: 8 })
          c.register(:maps, criticality: :optional, health: { error_rate: 0.25, min_calls: 8 })
        end
      end

      it "degrades at or above the rate once there are enough attempted calls" do
        record(:stripe, :default, :success, times: 6)
        record(:stripe, :default, :failure, times: 2)

        expect(row(:stripe)).to include(status: :degraded, affected_purposes: [ "default" ], reasons: [ "error_rate" ])
      end

      it "stays ok below min_calls, and does not count open-circuit calls toward it" do
        record(:stripe, :default, :failure, times: 7)
        record(:stripe, :default, :circuit_open, 0, times: 20)

        expect(row(:stripe)[:status]).to eq(:ok)
      end

      it "never elevates an optional dependency" do
        record(:maps, :default, :failure, times: 10)

        expect(row(:maps)).to include(status: :ok, reasons: [ "error_rate" ])
      end
    end

    context "with a slow rule" do
      before do
        StandardCircuit.configure do |c|
          c.register(:stripe, criticality: :critical, health: { slow_ms: 1000, min_calls: 5 })
          c.register(:sendgrid, criticality: :standard, health: { slow_ms: 1000, min_calls: 5 })
        end
      end

      it "degrades a critical dependency whose p95 is at or over the threshold" do
        record(:stripe, :default, :success, 1_000.0, times: 5)

        expect(row(:stripe)).to include(status: :degraded, reasons: [ "slow" ])
      end

      it "leaves a standard dependency ok, as the table says" do
        record(:sendgrid, :default, :success, 5_000.0, times: 5)

        expect(row(:sendgrid)).to include(status: :ok, reasons: [ "slow" ])
      end
    end

    it "judges each purpose on its own stats and criticality" do
      StandardCircuit.configure do |c|
        c.dependency :google_oauth, health: { error_rate: 0.5, min_calls: 4 } do |d|
          d.purpose :sign_in, criticality: :critical
          d.purpose :calendar, criticality: :optional
        end
      end
      record(:google_oauth, :calendar, :failure, times: 4)
      record(:google_oauth, :sign_in, :success, times: 4)

      expect(row(:google_oauth)).to include(status: :ok, affected_purposes: [ "calendar" ], reasons: [ "error_rate" ])
    end
  end

  describe "metrics_only" do
    before do
      StandardCircuit.configure do |c|
        c.register(:harness, criticality: :critical, metrics_only: true, health: { error_rate: 0.5, min_calls: 2 })
      end
    end

    it "reports, and degrades on a rule, but has no breaker findings and never fails readiness" do
      record(:harness, :default, :failure, times: 4)

      expect(row(:harness)).to include(status: :degraded, metrics_only: true, reasons: [ "error_rate" ])
    end

    it "never reports :unavailable even if its light reads red" do
      expect(row_with_color(:harness, "red")[:status]).to eq(:ok)
    end
  end

  describe "prefix dependencies" do
    before { StandardCircuit.configure { |c| c.register_prefix(:s3, criticality: :standard) } }

    it "has no circuits before one is used, and is ok" do
      expect(row(:s3)).to include(status: :ok, circuits: [])
    end

    it "lists the sub-circuits used so far, and the worst one decides" do
      StandardCircuit.run(:s3_uploads) { :ok }
      StandardCircuit.run(:s3_assets) { :ok }
      StandardCircuit.runner.lock(:s3_assets, :open)

      expect(row(:s3)).to include(status: :degraded, reasons: [ "open" ])
      expect(row(:s3)[:circuits].map { |c| c[:name] }).to contain_exactly("s3_uploads", "s3_assets")
    end
  end

  describe "StandardCircuit.health_rows" do
    it "is one row per dependency, in registration order" do
      StandardCircuit.configure do |c|
        c.register(:stripe, criticality: :critical)
        c.dependency(:harness)
        c.register_prefix(:s3)
      end

      expect(StandardCircuit.health_rows.map { |r| r[:name] }).to eq(%w[stripe harness s3])
    end
  end
end
