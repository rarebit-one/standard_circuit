module StandardCircuit
  class Config
    DEFAULT_THRESHOLD = 3
    DEFAULT_COOL_OFF = 30
    DEFAULT_WINDOW = 60

    CircuitSpec = Struct.new(
      :threshold,
      :cool_off_time,
      :window_size,
      :tracked_errors,
      :skipped_errors,
      keyword_init: true
    ) do
      def self.build(**opts)
        new(
          threshold: opts.fetch(:threshold, DEFAULT_THRESHOLD),
          cool_off_time: opts.fetch(:cool_off_time, DEFAULT_COOL_OFF),
          window_size: opts.fetch(:window_size, DEFAULT_WINDOW),
          tracked_errors: opts.fetch(:tracked_errors, NetworkErrors.defaults),
          skipped_errors: opts.fetch(:skipped_errors, [])
        )
      end
    end

    attr_accessor :sentry_enabled, :metric_prefix, :data_store, :logger
    attr_reader :circuits, :prefixes, :extra_notifiers

    def initialize
      @sentry_enabled = true
      @metric_prefix = "external"
      @data_store = Stoplight::DataStore::Memory.new
      @logger = nil
      @circuits = {}
      @prefixes = {}
      @extra_notifiers = []
    end

    def notifiers
      built = [ Notifiers::Logger.new(@logger) ]
      built << Notifiers::Sentry.new if @sentry_enabled
      built << Notifiers::Metrics.new(metric_prefix: @metric_prefix)
      built + @extra_notifiers
    end

    def register(name, **opts)
      @circuits[name.to_sym] = CircuitSpec.build(**opts)
    end

    def register_prefix(prefix, **opts)
      @prefixes[prefix.to_s] = CircuitSpec.build(**opts)
    end

    def add_notifier(notifier)
      @extra_notifiers << notifier
    end

    def spec_for(name)
      @circuits[name.to_sym] || spec_for_prefix(name)
    end

    private

    def spec_for_prefix(name)
      key = name.to_s
      _matched_prefix, spec = @prefixes.find { |prefix, _| key.start_with?("#{prefix}_") }
      spec
    end
  end
end
