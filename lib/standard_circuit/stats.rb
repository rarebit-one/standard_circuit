module StandardCircuit
  # Rolling, in-process call statistics per dependency and per purpose, fed by
  # `standard_circuit.run.completed` (see Stats::Subscriber).
  #
  # Each window holds the last +window_size+ calls in a fixed ring, so memory
  # is bounded by (dependencies + purposes) × window_size however much traffic
  # flows. Nothing is shared between processes: like the default Memory data
  # store, every worker has its own view.
  module Stats
    DEFAULT_WINDOW_SIZE = 100
    STATUSES = [ :success, :failure, :circuit_open ].freeze

    Sample = Struct.new(:status, :duration_ms)

    # The last +size+ calls for one dependency or purpose, plus a few
    # running values (last success/failure, consecutive failures) that
    # outlive the ring. Thread-safe.
    class Window
      def initialize(size, clock: -> { Time.now })
        @size = size
        @clock = clock
        @mutex = Mutex.new
        @samples = Array.new(size)
        @next = 0
        @count = 0
        @last_success_at = nil
        @last_failure_at = nil
        @consecutive_failures = 0
      end

      def record(status, duration_ms)
        now = @clock.call
        @mutex.synchronize do
          @samples[@next] = Sample.new(status, duration_ms)
          @next = (@next + 1) % @size
          @count += 1 if @count < @size

          case status
          when :success
            @last_success_at = now
            @consecutive_failures = 0
          when :failure
            @last_failure_at = now
            @consecutive_failures += 1
          end
        end
      end

      # A Hash describing the window. A window with no calls reports
      # `calls: 0` and nil rates, never zeros that would read as healthy.
      def snapshot
        samples, last_success_at, last_failure_at, consecutive_failures = @mutex.synchronize do
          [ @samples.first(@count).compact, @last_success_at, @last_failure_at, @consecutive_failures ]
        end
        Stats.summarize(samples, window_size: @size, last_success_at: last_success_at,
          last_failure_at: last_failure_at, consecutive_failures: consecutive_failures)
      end
    end

    # +samples+ in any order. Error rate and latency count only attempted
    # calls (success + failure): a :circuit_open call never reached the
    # upstream, so it is no evidence about it either way.
    def self.summarize(samples, window_size:, last_success_at: nil, last_failure_at: nil, consecutive_failures: 0)
      counts = STATUSES.to_h { |status| [ status, 0 ] }
      samples.each { |sample| counts[sample.status] += 1 if counts.key?(sample.status) }
      attempted = samples.select { |sample| sample.status == :success || sample.status == :failure }
      durations = attempted.map(&:duration_ms).compact.sort

      {
        calls: samples.size,
        window_size: window_size,
        counts: counts,
        error_rate: attempted.empty? ? nil : (counts[:failure].to_f / attempted.size).round(4),
        latency_ms: durations.empty? ? nil : { p50: percentile(durations, 50), p95: percentile(durations, 95) },
        last_success_at: last_success_at,
        last_failure_at: last_failure_at,
        consecutive_failures: consecutive_failures
      }
    end

    # Nearest-rank percentile of a sorted, non-empty Array.
    def self.percentile(sorted, pct)
      sorted[((pct / 100.0) * sorted.size).ceil.clamp(1, sorted.size) - 1]
    end

    # Every window, keyed by dependency name or [dependency, purpose].
    class Store
      attr_reader :window_size

      def initialize(window_size: DEFAULT_WINDOW_SIZE, clock: -> { Time.now })
        @window_size = window_size
        @clock = clock
        @windows = Concurrent::Map.new
      end

      # Changing the size drops every window: a ring can't be resized in place
      # without inventing or discarding history.
      def window_size=(size)
        return if size == @window_size

        @window_size = size
        clear!
      end

      def record(dependency, purpose, status, duration_ms)
        window(dependency).record(status, duration_ms)
        window([ dependency, purpose ]).record(status, duration_ms)
      end

      def for_dependency(dependency)
        snapshot(dependency)
      end

      def for_purpose(dependency, purpose)
        snapshot([ dependency, purpose ])
      end

      def clear!
        @windows.clear
      end

      private

      def window(key)
        @windows.compute_if_absent(key) { Window.new(@window_size, clock: @clock) }
      end

      def snapshot(key)
        @windows[key]&.snapshot || Stats.summarize([], window_size: @window_size)
      end
    end

    # Internal subscriber (see Subscribers#internal_subscribers). Records
    # calls that resolved to a dependency; never raises into the emitter.
    class Subscriber
      EVENT = "standard_circuit.run.completed".freeze

      def initialize(store)
        @store = store
      end

      def call(event_name, payload)
        return unless event_name == EVENT

        dependency = payload[:dependency]
        return if dependency.nil?

        @store.record(dependency, payload[:purpose], payload[:status], payload[:duration_ms])
      rescue StandardError => e
        warn "[StandardCircuit] stats recording failed: #{e.class}: #{e.message}"
      end
    end
  end
end
