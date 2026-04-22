require "spec_helper"
require "standard_circuit/mailer/delivery_method"

RSpec.describe StandardCircuit::Mailer::DeliveryMethod do
  let(:circuit_open_error) do
    Class.new(StandardError) do
      attr_reader :recipients, :subject

      def initialize(recipients:, subject:)
        @recipients = recipients
        @subject = subject
        super("circuit open: #{subject}")
      end
    end
  end

  let(:fake_mail) do
    Struct.new(:to, :subject).new([ "user@example.com" ], "Welcome")
  end

  before do
    StandardCircuit.configure do |c|
      c.register(:sendgrid, threshold: 3, cool_off_time: 30, tracked_errors: [ Net::OpenTimeout ])
    end
  end

  describe "instance underlying" do
    let(:underlying) { double("delivery", deliver!: :delivered) }

    it "delegates deliver! to the underlying instance under the circuit" do
      method = described_class.new(
        underlying: underlying,
        circuit: :sendgrid,
        retry_error_class: circuit_open_error
      )
      expect(underlying).to receive(:deliver!).with(fake_mail)
      method.deliver!(fake_mail)
    end
  end

  describe "symbol underlying" do
    let(:symbol_class) do
      Class.new do
        attr_reader :settings

        def initialize(settings = {})
          @settings = settings
        end

        def deliver!(mail)
          [ settings, mail ]
        end
      end
    end

    before do
      allow(ActionMailer::Base).to receive(:delivery_methods).and_return(
        smtp: Mail::SMTP, fake_symbol_delivery: symbol_class
      )
    end

    it "resolves the class via ActionMailer registry and instantiates with underlying_settings" do
      method = described_class.new(
        underlying: :fake_symbol_delivery,
        underlying_settings: { api_key: "secret" },
        circuit: :sendgrid,
        retry_error_class: circuit_open_error
      )

      result = method.deliver!(fake_mail)
      expect(result).to eq([ { api_key: "secret" }, fake_mail ])
    end

    it "raises ArgumentError for unregistered symbols" do
      method = described_class.new(
        underlying: :nope_not_registered,
        circuit: :sendgrid,
        retry_error_class: circuit_open_error
      )

      expect { method.deliver!(fake_mail) }
        .to raise_error(ArgumentError, /unknown delivery method :nope_not_registered/)
    end
  end

  describe "circuit-open translation" do
    let(:underlying) { double("delivery") }

    it "translates RedLight to retry_error_class with recipients and subject" do
      method = described_class.new(
        underlying: underlying,
        circuit: :sendgrid,
        retry_error_class: circuit_open_error
      )

      StandardCircuit.force_open(:sendgrid)

      error = nil
      begin
        method.deliver!(fake_mail)
      rescue StandardError => e
        error = e
      end

      expect(error).to be_a(circuit_open_error)
      expect(error.recipients).to eq([ "user@example.com" ])
      expect(error.subject).to eq("Welcome")
    end

    it "defaults to StandardCircuit::Mailer::CircuitOpenError when retry_error_class is not set" do
      method = described_class.new(
        underlying: underlying,
        circuit: :sendgrid
      )

      StandardCircuit.force_open(:sendgrid)

      error = nil
      begin
        method.deliver!(fake_mail)
      rescue StandardError => e
        error = e
      end

      expect(error).to be_a(StandardCircuit::Mailer::CircuitOpenError)
      expect(error.recipients).to eq([ "user@example.com" ])
      expect(error.subject).to eq("Welcome")
    end
  end
end
