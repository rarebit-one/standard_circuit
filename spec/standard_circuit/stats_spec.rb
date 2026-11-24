require "spec_helper"

RSpec.describe StandardCircuit::Stats do
  let(:now) { Time.utc(2026, 11, 23, 12, 0, 0) }
  let(:clock) { -> { now } }

  describe StandardCircuit::Stats::Window do
    subject(:window) { described_class.new(10, clock: clock) }

    it "distinguishes no evidence from health" do
      expect(window.snapshot).to eq(
        calls: 0,
        window_size: 10,
        counts: { success: 0, failure: 0, circuit_open: 0 },
        error_rate: nil,
        latency_ms: nil,
        fallbacks: 0,
        fallback_rate: nil,
        last_success_at: nil,
        last_failure_at: nil,
        consecutive_failures: 0
      )
    end

    it "counts statuses and rates failures over attempted calls only" do
      3.times { window.record(:success, 10.0) }
      window.record(:failure, 30.0)
      2.times { window.record(:circuit_open, 0) }

      expect(window.snapshot).to include(
        calls: 6,
        counts: { success: 3, failure: 1, circuit_open: 2 },
        error_rate: 0.25
      )
    end

    it "takes nearest-rank p50 and p95 latency over attempted calls" do
      (1..20).each { |ms| window.record(:success, ms.to_f) }
      window.record(:circuit_open, 0) # evicts 11; the ring holds 12..20 and this

      # Nearest rank over the 9 attempted calls: p50 is the 5th, p95 the 9th.
      expect(window.snapshot[:latency_ms]).to eq(p50: 16.0, p95: 20.0)
    end

    it "rates calls answered by a fallback over every call, open-circuit ones included" do
      2.times { window.record(:success, 10.0) }
      window.record(:failure, 30.0, true)
      window.record(:circuit_open, 0, true)

      expect(window.snapshot).to include(calls: 4, fallbacks: 2, fallback_rate: 0.5, error_rate: 0.3333)
    end

    it "tracks last success, last failure and consecutive failures" do
      success_at = now
      window.record(:success, 1.0)
      allow(clock).to receive(:call).and_return(now + 60)
      2.times { window.record(:failure, 1.0) }
      window.record(:circuit_open, 0)

      expect(window.snapshot).to include(
        last_success_at: success_at, last_failure_at: now + 60, consecutive_failures: 2
      )

      window.record(:success, 1.0)
      expect(window.snapshot[:consecutive_failures]).to eq(0)
    end

    it "stays bounded however many calls it sees" do
      10_000.times { |i| window.record(i.even? ? :success : :failure, 1.0) }

      expect(window.snapshot).to include(calls: 10, counts: { success: 5, failure: 5, circuit_open: 0 })
      expect(window.instance_variable_get(:@samples).size).to eq(10)
    end

    it "is safe to record into from many threads" do
      window = described_class.new(100, clock: clock)
      threads = Array.new(8) do
        Thread.new { 1_000.times { window.record(:failure, 1.0) } }
      end
      threads.each(&:join)

      expect(window.snapshot).to include(calls: 100, counts: { success: 0, failure: 100, circuit_open: 0 },
        consecutive_failures: 8_000)
    end
  end

  describe StandardCircuit::Stats::Store do
    subject(:store) { described_class.new(window_size: 5, clock: clock) }

    it "keeps one window per dependency and one per purpose" do
      store.record(:google_oauth, :sign_in, :success, 1.0)
      store.record(:google_oauth, :calendar, :failure, 1.0)

      expect(store.for_dependency(:google_oauth)[:calls]).to eq(2)
      expect(store.for_purpose(:google_oauth, :sign_in)[:counts]).to include(success: 1, failure: 0)
      expect(store.for_purpose(:google_oauth, :calendar)[:counts]).to include(success: 0, failure: 1)
    end

    it "creates each window once under concurrent first use" do
      threads = Array.new(8) { Thread.new { 100.times { store.record(:dep, :p, :success, 1.0) } } }
      threads.each(&:join)

      expect(store.instance_variable_get(:@windows).size).to eq(2)
      expect(store.for_dependency(:dep)[:calls]).to eq(5)
    end

    it "reports an empty window for a name it has never seen" do
      expect(store.for_purpose(:nope, :x)).to include(calls: 0, window_size: 5, error_rate: nil)
    end

    it "drops every window when resized" do
      store.record(:dep, :p, :success, 1.0)
      store.window_size = 50

      expect(store.for_dependency(:dep)).to include(calls: 0, window_size: 50)
    end
  end

  describe StandardCircuit::Stats::Subscriber do
    let(:store) { StandardCircuit::Stats::Store.new(window_size: 5) }
    let(:subscriber) { described_class.new(store) }

    it "records run.completed events that resolved to a dependency" do
      subscriber.call("standard_circuit.run.completed",
        dependency: :stripe, purpose: :default, status: :success, duration_ms: 3.0)
      subscriber.call("standard_circuit.run.completed",
        dependency: nil, purpose: nil, status: :circuit_open, duration_ms: 0)
      subscriber.call("standard_circuit.circuit.opened", circuit: "stripe")

      expect(store.for_dependency(:stripe)[:calls]).to eq(1)
    end

    it "records whether a fallback answered the call" do
      subscriber.call("standard_circuit.run.completed",
        dependency: :stripe, purpose: :default, status: :failure, duration_ms: 3.0, fallback_used: true)
      subscriber.call("standard_circuit.run.completed",
        dependency: :stripe, purpose: :default, status: :success, duration_ms: 3.0)

      expect(store.for_dependency(:stripe)).to include(fallbacks: 1, fallback_rate: 0.5)
      expect(store.for_purpose(:stripe, :default)).to include(fallbacks: 1)
    end

    it "never raises" do
      allow(store).to receive(:record).and_raise(RuntimeError, "boom")

      expect {
        subscriber.call("standard_circuit.run.completed", dependency: :x, purpose: :default, status: :success)
      }.to output(/stats recording failed: RuntimeError: boom/).to_stderr
    end
  end

  describe "on Rails.event" do
    # The same stand-in the Subscribers spec uses: Rails 8.1 hosts emit and
    # subscribe through Rails.event, not ActiveSupport::Notifications.
    before do
      listeners = []
      bus = double("Rails.event")
      allow(bus).to receive(:notify) { |name, **payload| listeners.each { |l| l.emit(name: name, payload: payload) } }
      allow(bus).to receive(:subscribe) { |listener| listeners << listener }
      allow(bus).to receive(:unsubscribe) { |listener| listeners.delete(listener) }
      stub_const("Rails", double("Rails", event: bus))
    end

    it "records calls" do
      StandardCircuit.configure { |c| c.register(:stripe) }
      StandardCircuit.run(:stripe) { :ok }

      expect(StandardCircuit.dependency(:stripe).stats[:calls]).to eq(1)
    end
  end
end
