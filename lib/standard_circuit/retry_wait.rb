module StandardCircuit
  # The `wait:` for a job's `retry_on Stoplight::Error::RedLight` (see
  # StandardCircuit.retry_wait). `:polynomially_longer` alone retries after
  # ~3s and ~18s, while the breaker is still cooling off, so those attempts
  # land on an open circuit and are wasted. This keeps the polynomial backoff
  # (`executions**4 + 2` seconds) but never waits less than the longest
  # cool-off behind the names given, read from the registration at retry
  # time so a cool_off_time change carries over.
  #
  # ActiveJob calls a Proc `wait` with the execution count alone and adds no
  # jitter of its own, so the jitter is added here, on top of the floor: jobs
  # an outage queued up don't all retry at the same instant, and none retries
  # before the cool-off.
  module RetryWait
    # ActiveJob's own default `retry_jitter`, for when ActiveJob isn't loaded.
    DEFAULT_JITTER = 0.15

    class << self
      # +names+ are circuits or dependencies (see Config#cool_off_time_for).
      # +jitter+ is a fraction of the delay, like `retry_on`'s; nil reads
      # ActiveJob::Base.retry_jitter at retry time.
      def build(names, jitter: nil)
        raise ArgumentError, "retry_wait needs at least one circuit or dependency name" if names.empty?
        unless jitter.nil? || (jitter.is_a?(Numeric) && jitter >= 0)
          raise ArgumentError, "jitter must be nil or a non-negative Numeric; got #{jitter.inspect}"
        end

        names = names.map(&:to_sym).freeze
        lambda do |executions|
          cool_off = names.map { |name| StandardCircuit.config.cool_off_time_for(name) }.max
          delay = [ (executions**4) + 2, cool_off ].max
          delay + (Kernel.rand * delay * (jitter || default_jitter))
        end
      end

      private

      def default_jitter
        defined?(::ActiveJob::Base) ? ::ActiveJob::Base.retry_jitter.to_f : DEFAULT_JITTER
      end
    end
  end
end
