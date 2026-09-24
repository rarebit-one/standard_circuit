require "spec_helper"
require "active_job"
require "active_job/test_helper"

RSpec.describe StandardCircuit::Mailer::Retry do
  include ActiveJob::TestHelper

  let(:options) { StandardCircuit::Config::MAILER_RETRY_DEFAULTS }
  let(:circuit_open) do
    StandardCircuit::Mailer::CircuitOpenError.new(
      recipients: [ "Ada@Example.COM", "bob@example.com", "carol@other.test", "not-an-address" ],
      subject: "secret subject"
    )
  end
  let(:logger) { instance_double(Logger, error: nil) }

  # A fresh subclass per example: retry_on mutates the class it's called on,
  # and MailDeliveryJob itself is process-global.
  let(:job_class) do
    error = circuit_open
    Class.new(ActionMailer::MailDeliveryJob) do
      def self.name = "TestMailDeliveryJob"
      define_method(:perform) { |*| raise error }
    end
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.logger = Logger.new(IO::NULL)
    StandardCircuit.config.logger = logger
  end

  after { StandardCircuit.config.logger = nil }

  def build_job
    job_class.new("UserMailer", "welcome", "deliver_now", args: [ 1 ])
  end

  describe ".install" do
    it "adds a retry_on CircuitOpenError handler" do
      expect(described_class.install(job_class, options)).to be(true)
      expect(described_class.installed?(job_class)).to be(true)
    end

    it "is idempotent — repeated installs (code reloads) don't stack handlers" do
      3.times { described_class.install(job_class, options) }

      handlers = job_class.rescue_handlers.count { |(name, _)| name == StandardCircuit::Mailer::CircuitOpenError.name }
      expect(handlers).to eq(1)
    end

    it "stands down when the host already installed its own handler" do
      job_class.retry_on(StandardCircuit::Mailer::CircuitOpenError, attempts: 2)

      expect(described_class.install(job_class, options)).to be(false)
    end

    it "leaves the parent MailDeliveryJob untouched" do
      described_class.install(job_class, options)
      expect(ActionMailer::MailDeliveryJob.rescue_handlers).not_to include(job_class.rescue_handlers.last)
    end

    context "when performed" do
      before do
        stub_const("UserMailer", Class.new(ActionMailer::Base))
        allow(described_class).to receive(:report_exhausted)
      end

      it "re-enqueues the delivery with the configured wait while attempts remain" do
        described_class.install(job_class, options.merge(jitter: 0.0))

        before = Time.now.to_f
        build_job.perform_now

        expect(enqueued_jobs.size).to eq(1)
        expect(enqueued_jobs.first[:at]).to be_within(2).of(before + 90)
        expect(described_class).not_to have_received(:report_exhausted)
      end

      it "re-enqueues without raising on every attempt before the last" do
        described_class.install(job_class, options)
        job = build_job

        (options[:attempts] - 1).times { expect { job.perform_now }.not_to raise_error }

        expect(enqueued_jobs.size).to eq(options[:attempts] - 1)
        expect(described_class).not_to have_received(:report_exhausted)
      end

      it "reports, then re-raises once attempts are exhausted, so the job fails instead of being dropped" do
        described_class.install(job_class, options)
        job = build_job

        (options[:attempts] - 1).times { job.perform_now }
        expect { job.perform_now }.to raise_error(circuit_open)

        expect(enqueued_jobs.size).to eq(options[:attempts] - 1)
        expect(described_class).to have_received(:report_exhausted).with(job, circuit_open).once
      end

      it "fails the job through the adapter after the retries run out" do
        stub_const("TestMailDeliveryJob", job_class) # retries deserialize by class name
        described_class.install(job_class, options)

        # The test adapter performs each enqueue (and each scheduled retry)
        # immediately, the way a worker would pick them up.
        adapter = ActiveJob::Base.queue_adapter
        adapter.perform_enqueued_jobs = true
        adapter.perform_enqueued_at_jobs = true

        expect {
          job_class.perform_later("UserMailer", "welcome", "deliver_now", args: [ 1 ])
        }.to raise_error(StandardCircuit::Mailer::CircuitOpenError)

        expect(performed_jobs.size).to eq(options[:attempts])
        expect(described_class).to have_received(:report_exhausted).once
      end

      it "still re-raises the original error when reporting itself fails" do
        allow(described_class).to receive(:report_exhausted).and_raise(RuntimeError, "sentry down")
        described_class.install(job_class, options.merge(attempts: 1))

        expect { build_job.perform_now }.to raise_error(circuit_open)
        expect(logger).to have_received(:error).with(/failed to report mail retry exhaustion: RuntimeError: sentry down/)
      end
    end
  end

  describe ".report_exhausted" do
    let(:job) { build_job.tap { |j| j.executions = 5 } }

    before do
      allow(::Sentry).to receive(:initialized?).and_return(true)
      allow(::Sentry).to receive(:capture_message)
    end

    it "logs metadata with recipient domains only — never addresses or subjects" do
      described_class.report_exhausted(job, circuit_open)

      expect(logger).to have_received(:error) do |line|
        expect(line).to include("retries exhausted", "UserMailer", "welcome", "example.com", "other.test", job.job_id)
        expect(line).not_to include("ada@", "bob@", "secret subject")
      end
    end

    it "sends a Sentry :error event fingerprinted by mailer and action" do
      described_class.report_exhausted(job, circuit_open)

      expect(::Sentry).to have_received(:capture_message).with(
        described_class::EXHAUSTED_MESSAGE,
        level: :error,
        fingerprint: [ described_class::FINGERPRINT, "UserMailer", "welcome" ],
        extra: {
          mailer_class: "UserMailer",
          mail_action: "welcome",
          recipient_domains: [ "example.com", "other.test" ],
          job_id: job.job_id,
          executions: 5
        }
      )
    end

    it "skips Sentry when sentry_enabled is false" do
      StandardCircuit.config.sentry_enabled = false
      described_class.report_exhausted(job, circuit_open)
      expect(::Sentry).not_to have_received(:capture_message)
    end

    it "skips Sentry when Sentry isn't initialized" do
      allow(::Sentry).to receive(:initialized?).and_return(false)
      described_class.report_exhausted(job, circuit_open)
      expect(::Sentry).not_to have_received(:capture_message)
    end

    it "emits standard_circuit.mailer.retries_exhausted for host subscribers" do
      allow(StandardCircuit::EventEmitter).to receive(:emit)
      described_class.report_exhausted(job, circuit_open)
      expect(StandardCircuit::EventEmitter).to have_received(:emit)
        .with("standard_circuit.mailer.retries_exhausted", hash_including(recipient_domains: [ "example.com", "other.test" ]))
    end
  end

  describe "wiring through StandardCircuit.configure" do
    around do |example|
      saved = ActionMailer::MailDeliveryJob.rescue_handlers
      described_class.reset_on_load_registration!
      example.run
    ensure
      ActionMailer::MailDeliveryJob.rescue_handlers = saved
      described_class.reset_on_load_registration!
      StandardCircuit.config.mailer_retry = nil
    end

    it "installs nothing by default" do
      StandardCircuit.configure { |_c| nil }
      expect(described_class.installed?(ActionMailer::MailDeliveryJob)).to be(false)
    end

    it "installs on ActionMailer::MailDeliveryJob when mailer_retry is set" do
      StandardCircuit.configure { |c| c.mailer_retry = true }
      expect(described_class.installed?(ActionMailer::MailDeliveryJob)).to be(true)
    end

    it "installs exactly once across repeated configure calls" do
      3.times { StandardCircuit.configure { |c| c.mailer_retry = { attempts: 3 } } }

      handlers = ActionMailer::MailDeliveryJob.rescue_handlers
        .count { |(name, _)| name == StandardCircuit::Mailer::CircuitOpenError.name }
      expect(handlers).to eq(1)
    end
  end
end
