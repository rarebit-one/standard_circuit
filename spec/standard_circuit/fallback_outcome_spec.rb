require "spec_helper"

# What run.completed, the request metric and stats report when a fallback's
# value is returned. Stoplight calls the fallback itself (with the error for a
# tracked failure, with nil while red) and returns its value, so without help
# the runner would see every such call as a success.
RSpec.describe StandardCircuit, ".run fallback outcomes" do
  def capture(pattern)
    events = []
    callback = ->(name, _s, _f, _i, payload) { events << [ name, payload ] }
    ActiveSupport::Notifications.subscribed(callback, pattern) { yield }
    events
  end

  def completed(&block)
    capture("standard_circuit.run.completed", &block).map(&:last)
  end

  def color(name) = StandardCircuit.runner.light_for(name).color

  # The stats subscriber is wired by `configure`, but once any spec has
  # required "standard_circuit/rspec", its subscriber teardown also runs as a
  # hook of this group, after this group's own `before`. Wire it again here.
  def record_stats! = StandardCircuit.subscribers.setup!

  def register(name)
    StandardCircuit.config.register(name, threshold: 2, cool_off_time: 60,
                                    tracked_errors: [ RuntimeError, skipped_error ], skipped_errors: [ skipped_error ])
  end

  # Runs +name+ with +fallback+ once per entry in +errors+, each call raising
  # that error; swallows whatever is re-raised.
  def raise_each(name, fallback, *errors)
    errors.each do |error|
      StandardCircuit.run(name, fallback: fallback) { raise error }
    rescue RuntimeError, skipped_error
      nil
    end
  end

  let(:skipped_error) { stub_const("FallbackOutcomeSkippedError", Class.new(StandardError)) }

  before do
    # One backend for the whole example: subscribe and emit on AS::Notifications.
    hide_const("Rails") if defined?(::Rails)
    described_class.configure { register(:flaky) }
  end

  describe "a failure the fallback absorbed" do
    it "returns the fallback's value, calling it once with the error" do
      calls = []
      result = described_class.run(:flaky, fallback: ->(error) { calls << error; :degraded }) { raise "boom" }

      expect(result).to eq(:degraded)
      expect(calls.size).to eq(1)
      expect(calls.first).to be_a(RuntimeError).and have_attributes(message: "boom")
    end

    it "reports status: :failure with the absorbed error and fallback_used: true" do
      payloads = completed { described_class.run(:flaky, fallback: -> { :degraded }) { raise "boom" } }

      expect(payloads.size).to eq(1)
      expect(payloads.first).to include(
        circuit: "flaky", status: :failure, error_class: "RuntimeError", error_message: "boom",
        criticality: :standard, dependency: :flaky, purpose: :default, fallback_used: true
      )
      expect(payloads.first[:duration_ms]).to be_a(Numeric)
    end

    it "emits the request metric with status failure" do
      allow(::Sentry::Metrics).to receive(:count)
      allow(::Sentry::Metrics).to receive(:distribution)

      described_class.run(:flaky, fallback: -> { :degraded }) { raise "boom" }

      expect(::Sentry::Metrics).to have_received(:count)
        .with("external.request", value: 1, attributes: { service: "flaky", status: "failure" })
      expect(::Sentry::Metrics).to have_received(:distribution)
        .with("external.request.duration", kind_of(Numeric), unit: "millisecond", attributes: { service: "flaky", status: "failure" })
    end

    it "counts as a failure in the rolling stats" do
      record_stats!
      described_class.run(:flaky) { :ok }
      described_class.run(:flaky, fallback: -> { :degraded }) { raise "boom" }

      expect(described_class.dependency(:flaky).stats)
        .to include(counts: { success: 1, failure: 1, circuit_open: 0 }, error_rate: 0.5, consecutive_failures: 1)
    end

    it "still counts towards tripping the breaker, as without a fallback" do
      described_class.run(:flaky, fallback: -> { :degraded }) { raise "boom" }
      expect(color(:flaky)).to eq(Stoplight::Color::GREEN)

      described_class.run(:flaky, fallback: -> { :degraded }) { raise "boom" }
      expect(color(:flaky)).to eq(Stoplight::Color::RED)
    end

    it "does not emit fallback_invoked (only an open or forced-open circuit does)" do
      events = capture(/\Astandard_circuit\.circuit\.fallback_invoked\z/) do
        described_class.run(:flaky, fallback: -> { :degraded }) { raise "boom" }
      end

      expect(events).to be_empty
    end

    it "lets an error the fallback raises propagate, as before" do
      payloads = completed do
        expect {
          described_class.run(:flaky, fallback: ->(_e) { raise ArgumentError, "fallback broke" }) { raise "boom" }
        }.to raise_error(ArgumentError, "fallback broke")
      end

      expect(payloads.map { |p| p.slice(:status, :error_class, :fallback_used) })
        .to eq([ { status: :failure, error_class: "ArgumentError", fallback_used: false } ])
    end
  end

  describe "an open circuit with a fallback" do
    before do
      record_stats!
      2.times { described_class.run(:flaky, fallback: -> { :degraded }) { raise "boom" } }
    end

    it "returns the fallback's value without running the block, calling the fallback once with nil" do
      calls = []
      result = described_class.run(:flaky, fallback: ->(error) { calls << error; :degraded }) { raise "never runs" }

      expect(result).to eq(:degraded)
      expect(calls).to eq([ nil ])
    end

    it "reports status: :circuit_open and fallback_used: true" do
      payloads = completed { described_class.run(:flaky, fallback: -> { :degraded }) { :never } }

      expect(payloads.map { |p| p.slice(:status, :error_class, :error_message, :fallback_used) })
        .to eq([ { status: :circuit_open, error_class: nil, error_message: nil, fallback_used: true } ])
    end

    it "emits the request metric with status circuit_open" do
      allow(::Sentry::Metrics).to receive(:count)
      allow(::Sentry::Metrics).to receive(:distribution)

      described_class.run(:flaky, fallback: -> { :degraded }) { :never }

      expect(::Sentry::Metrics).to have_received(:count)
        .with("external.request", value: 1, attributes: { service: "flaky", status: "circuit_open" })
    end

    it "counts as circuit_open, not as an attempted call, in the rolling stats" do
      described_class.run(:flaky, fallback: -> { :degraded }) { :never }

      expect(described_class.dependency(:flaky).stats).to include(counts: { success: 0, failure: 2, circuit_open: 1 })
    end

    it "reports fallback_used: false when there is no fallback and RedLight is raised" do
      payloads = completed do
        expect { described_class.run(:flaky) { :never } }.to raise_error(Stoplight::Error::RedLight)
      end

      expect(payloads.map { |p| p.slice(:status, :error_class, :fallback_used) })
        .to eq([ { status: :circuit_open, error_class: "Stoplight::Error::RedLight", fallback_used: false } ])
    end
  end

  describe "a forced-open circuit" do
    it "reports status: :circuit_open and fallback_used: true when a fallback is returned" do
      calls = []
      payloads = completed do
        described_class.force_open(:flaky) do
          expect(described_class.run(:flaky, fallback: ->(error) { calls << error; :degraded }) { :never }).to eq(:degraded)
        end
      end

      expect(calls).to eq([ nil ])
      expect(payloads.map { |p| p.slice(:status, :fallback_used) }).to eq([ { status: :circuit_open, fallback_used: true } ])
    end

    it "reports fallback_used: false when RedLight is raised" do
      payloads = completed do
        described_class.force_open(:flaky) do
          expect { described_class.run(:flaky) { :never } }.to raise_error(Stoplight::Error::RedLight)
        end
      end

      expect(payloads.map { |p| p.slice(:status, :fallback_used) }).to eq([ { status: :circuit_open, fallback_used: false } ])
    end
  end

  describe "a fallback the runner calls itself that raises" do
    it "reports fallback_used: false for a forced-open circuit, still emitting fallback_invoked" do
      events = capture(/\Astandard_circuit\.(run|circuit)\./) do
        described_class.force_open(:flaky) do
          expect {
            described_class.run(:flaky, fallback: ->(_e) { raise ArgumentError, "fallback broke" }) { :never }
          }.to raise_error(ArgumentError, "fallback broke")
        end
      end

      expect(events.map { |(name, payload)| [ name, payload.slice(:status, :reason, :fallback_used) ] }).to eq([
        [ "standard_circuit.circuit.fallback_invoked", { reason: :forced_open } ],
        [ "standard_circuit.run.completed", { status: :circuit_open, fallback_used: false } ]
      ])
    end
  end

  # An untracked RedLight raised inside the block (an inner circuit that is
  # open) reaches the runner, which answers it with the fallback itself.
  describe "a RedLight raised inside the block" do
    let(:inner_red) { Stoplight::Error::RedLight.new("inner", cool_off_time: 60, retry_after: nil) }

    it "reports status: :circuit_open and fallback_used: true once the fallback returned" do
      calls = []
      events = capture(/\Astandard_circuit\.(run|circuit)\./) do
        expect(described_class.run(:flaky, fallback: ->(error) { calls << error; :degraded }) { raise inner_red }).to eq(:degraded)
      end

      expect(calls).to eq([ nil ])
      expect(events.map { |(name, payload)| [ name, payload.slice(:status, :reason, :error_class, :fallback_used) ] }).to eq([
        [ "standard_circuit.circuit.fallback_invoked", { reason: :circuit_open } ],
        [ "standard_circuit.run.completed", { status: :circuit_open, error_class: "Stoplight::Error::RedLight", fallback_used: true } ]
      ])
    end

    it "reports fallback_used: false when that fallback raises" do
      payloads = completed do
        expect {
          described_class.run(:flaky, fallback: ->(_e) { raise ArgumentError, "fallback broke" }) { raise inner_red }
        }.to raise_error(ArgumentError, "fallback broke")
      end

      expect(payloads.map { |p| p.slice(:status, :fallback_used) }).to eq([ { status: :circuit_open, fallback_used: false } ])
    end
  end

  describe "calls the fallback played no part in" do
    it "reports fallback_used: false on success, with or without a fallback" do
      payloads = completed do
        described_class.run(:flaky, fallback: -> { :degraded }) { :ok }
        described_class.run(:flaky) { :ok }
      end

      expect(payloads.map { |p| p.slice(:status, :fallback_used) }).to eq([ { status: :success, fallback_used: false } ] * 2)
    end

    it "reports fallback_used: false on a failure that was raised" do
      payloads = completed do
        expect { described_class.run(:flaky) { raise "boom" } }.to raise_error(RuntimeError)
      end

      expect(payloads.map { |p| p.slice(:status, :fallback_used) }).to eq([ { status: :failure, fallback_used: false } ])
    end
  end

  # A skipped error is never handed to the fallback: stoplight re-raises it and
  # records the call as a success for the breaker. That was so before the
  # fallback outcome was reported and stays so.
  describe "a skipped error with a fallback" do
    it "re-raises without calling the fallback, reporting status: :failure and fallback_used: false" do
      calls = []
      payloads = completed do
        expect {
          described_class.run(:flaky, fallback: ->(error) { calls << error; :degraded }) { raise skipped_error, "caller" }
        }.to raise_error(skipped_error)
      end

      expect(calls).to be_empty
      expect(payloads.map { |p| p.slice(:status, :error_class, :fallback_used) })
        .to eq([ { status: :failure, error_class: skipped_error.name, fallback_used: false } ])
    end

    it "leaves the breaker exactly as it would without a fallback" do
      register(:with_fallback)
      register(:without_fallback)

      # The skipped error counts as a success between the two failures, so
      # neither breaker reaches its threshold of two...
      raise_each(:with_fallback, -> { :degraded }, "boom", skipped_error, "boom")
      raise_each(:without_fallback, nil, "boom", skipped_error, "boom")
      expect([ color(:with_fallback), color(:without_fallback) ]).to eq([ Stoplight::Color::GREEN ] * 2)

      # ...until a second failure in a row.
      raise_each(:with_fallback, -> { :degraded }, "boom")
      raise_each(:without_fallback, nil, "boom")
      expect([ color(:with_fallback), color(:without_fallback) ]).to eq([ Stoplight::Color::RED ] * 2)
    end
  end

  describe "a metrics-only circuit" do
    before do
      described_class.configure do |c|
        c.register(:observed, metrics_only: true, tracked_errors: [ RuntimeError ])
      end
    end

    it "reports a failure the fallback absorbed as status: :failure with fallback_used: true" do
      calls = []
      payloads = completed do
        expect(described_class.run(:observed, fallback: ->(error) { calls << error; :degraded }) { raise "boom" }).to eq(:degraded)
      end

      expect(calls.map(&:message)).to eq([ "boom" ])
      expect(payloads.map { |p| p.slice(:status, :error_class, :error_message, :fallback_used) })
        .to eq([ { status: :failure, error_class: "RuntimeError", error_message: "boom", fallback_used: true } ])
    end

    it "reports fallback_used: false on success" do
      payloads = completed { described_class.run(:observed, fallback: -> { :degraded }) { :ok } }

      expect(payloads.map { |p| p.slice(:status, :fallback_used) }).to eq([ { status: :success, fallback_used: false } ])
    end
  end
end
