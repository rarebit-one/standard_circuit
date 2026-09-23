require "spec_helper"
require "aws-sdk-s3"

RSpec.describe StandardCircuit::AdapterErrors::Aws do
  describe ".server_errors" do
    it "lists networking errors and the ServiceError base class" do
      expect(described_class.server_errors).to eq(
        [ Seahorse::Client::NetworkingError, Aws::Errors::ServiceError ]
      )
    end

    it "covers dynamically generated 5xx service errors via ServiceError" do
      error = Aws::S3::Errors::ServiceUnavailable.new(nil, "Service Unavailable")
      expect(described_class.server_errors.any? { |klass| klass === error }).to be(true)
    end

    it "returns [] when aws-sdk isn't loaded" do
      hide_const("Seahorse")
      hide_const("Aws")
      expect(described_class.server_errors).to eq([])
    end
  end

  describe ".caller_errors" do
    it "lists S3 NoSuchKey and AccessDenied" do
      expect(described_class.caller_errors).to eq(
        [ Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::AccessDenied ]
      )
    end

    it "lists errors that ServiceError also matches (hence the default skip list)" do
      expect(described_class.caller_errors).to all(be < Aws::Errors::ServiceError)
    end

    it "returns [] when aws-sdk-s3 isn't loaded" do
      hide_const("Aws")
      expect(described_class.caller_errors).to eq([])
    end
  end
end
