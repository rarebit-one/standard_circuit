require "spec_helper"
require "aws-sdk-s3"
require "postmark"

RSpec.describe StandardCircuit::ErrorTaxonomies do
  shared_examples "an adapter taxonomy" do |adapter_module|
    it "combines NetworkErrors.defaults with the adapter's server_errors" do
      expected = StandardCircuit::NetworkErrors.defaults + adapter_module.server_errors
      expect(described_class.tracked).to eq(expected)
    end

    it "returns a fresh array each call (callers can mutate without leakage)" do
      first = described_class.tracked
      first << StandardError
      expect(described_class.tracked).not_to include(StandardError)
    end
  end

  describe described_class::Stripe do
    it_behaves_like "an adapter taxonomy", StandardCircuit::AdapterErrors::Stripe
  end

  describe described_class::Smtp do
    it_behaves_like "an adapter taxonomy", StandardCircuit::AdapterErrors::Smtp
  end

  describe described_class::Aws do
    it_behaves_like "an adapter taxonomy", StandardCircuit::AdapterErrors::Aws
  end

  describe described_class::Faraday do
    it_behaves_like "an adapter taxonomy", StandardCircuit::AdapterErrors::Faraday
  end

  describe described_class::Postmark do
    it_behaves_like "an adapter taxonomy", StandardCircuit::AdapterErrors::Postmark
  end

  describe ".default_skipped_for" do
    let(:aws_caller_errors) { [ Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::AccessDenied ] }

    it "returns the Postmark caller errors when the tracked list includes Postmark::HttpServerError" do
      expect(described_class.default_skipped_for(described_class::Postmark.tracked))
        .to eq([ Postmark::ApiInputError, Postmark::InvalidApiKeyError ])
    end


    it "returns the AWS caller errors when the tracked list includes Aws::Errors::ServiceError" do
      expect(described_class.default_skipped_for(described_class::Aws.tracked)).to match_array(aws_caller_errors)
    end

    it "returns the AWS caller errors when a tracked class covers them via inheritance" do
      expect(described_class.default_skipped_for([ Aws::S3::Errors::ServiceError ])).to match_array(aws_caller_errors)
    end

    it "returns [] for tracked lists that don't cover the AWS caller errors" do
      [
        StandardCircuit::NetworkErrors.defaults,
        described_class::Stripe.tracked,
        described_class::Smtp.tracked,
        described_class::Faraday.tracked,
        [ Seahorse::Client::NetworkingError ]
      ].each do |tracked|
        expect(described_class.default_skipped_for(tracked)).to eq([])
      end
    end

    it "ignores non-class matchers in the tracked list" do
      expect(described_class.default_skipped_for([ ->(_e) { true }, "Aws::Errors::ServiceError" ])).to eq([])
    end

    it "returns [] when aws-sdk isn't loaded" do
      allow(StandardCircuit::AdapterErrors::Aws).to receive(:caller_errors).and_return([])
      expect(described_class.default_skipped_for(described_class::Aws.tracked)).to eq([])
    end
  end

  describe "AWS circuit behaviour with the default skip list" do
    let(:access_denied) { Aws::S3::Errors::AccessDenied.new(nil, "Access Denied") }
    let(:no_such_key) { Aws::S3::Errors::NoSuchKey.new(nil, "The specified key does not exist.") }
    let(:service_unavailable) { Aws::S3::Errors::ServiceUnavailable.new(nil, "Service Unavailable") }
    let(:networking_error) { Seahorse::Client::NetworkingError.new(Errno::ECONNRESET.new) }

    before do
      allow(::Sentry::Metrics).to receive(:count)
      allow(::Sentry::Metrics).to receive(:distribution)
    end

    def fail_with(name, error, times:)
      times.times do
        expect { StandardCircuit.run(name) { raise error } }.to raise_error(error.class)
      end
    end

    def circuit_color(name)
      StandardCircuit.runner.light_for(name).color
    end

    shared_examples "an S3 breaker that ignores caller errors" do |circuit|
      it "does not trip on repeated AccessDenied" do
        fail_with(circuit, access_denied, times: 3)
        expect(circuit_color(circuit)).to eq(Stoplight::Color::GREEN)
      end

      it "does not trip on repeated NoSuchKey" do
        fail_with(circuit, no_such_key, times: 3)
        expect(circuit_color(circuit)).to eq(Stoplight::Color::GREEN)
      end

      it "trips on AWS 5xx (ServiceUnavailable)" do
        fail_with(circuit, service_unavailable, times: 2)
        expect(circuit_color(circuit)).to eq(Stoplight::Color::RED)
      end

      it "trips on Seahorse::Client::NetworkingError" do
        fail_with(circuit, networking_error, times: 2)
        expect(circuit_color(circuit)).to eq(Stoplight::Color::RED)
      end
    end

    context "when registered by name" do
      before do
        StandardCircuit.configure do |c|
          c.register(:s3, threshold: 2, tracked_errors: described_class::Aws.tracked)
        end
      end

      it "defaults skipped_errors to the AWS caller errors" do
        expect(StandardCircuit.config.spec_for(:s3).skipped_errors)
          .to contain_exactly(Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::AccessDenied)
      end

      it_behaves_like "an S3 breaker that ignores caller errors", :s3
    end

    context "when registered by prefix" do
      before do
        StandardCircuit.configure do |c|
          c.register_prefix(:s3, threshold: 2, tracked_errors: described_class::Aws.tracked)
        end
      end

      it "defaults skipped_errors to the AWS caller errors" do
        expect(StandardCircuit.config.spec_for(:s3_uploads).skipped_errors)
          .to contain_exactly(Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::AccessDenied)
      end

      it_behaves_like "an S3 breaker that ignores caller errors", :s3_uploads
    end

    context "when skipped_errors is passed explicitly" do
      it "keeps an explicit empty list, so caller errors trip the breaker again" do
        StandardCircuit.configure do |c|
          c.register(:s3, threshold: 2, tracked_errors: described_class::Aws.tracked, skipped_errors: [])
        end

        expect(StandardCircuit.config.spec_for(:s3).skipped_errors).to eq([])
        fail_with(:s3, access_denied, times: 2)
        expect(circuit_color(:s3)).to eq(Stoplight::Color::RED)
      end

      it "keeps an explicit non-empty list as given" do
        StandardCircuit.configure do |c|
          c.register_prefix(:s3, tracked_errors: described_class::Aws.tracked,
            skipped_errors: [ Aws::S3::Errors::NoSuchKey ])
        end

        expect(StandardCircuit.config.spec_for(:s3_uploads).skipped_errors).to eq([ Aws::S3::Errors::NoSuchKey ])
      end
    end

    it "keeps skipped_errors empty for non-AWS taxonomies" do
      StandardCircuit.configure do |c|
        c.register(:stripe, tracked_errors: described_class::Stripe.tracked)
        c.register(:smtp, tracked_errors: described_class::Smtp.tracked)
        c.register(:api, tracked_errors: described_class::Faraday.tracked)
        c.register(:plain)
      end

      %i[stripe smtp api plain].each do |name|
        expect(StandardCircuit.config.spec_for(name).skipped_errors).to eq([])
      end
    end
  end
end
