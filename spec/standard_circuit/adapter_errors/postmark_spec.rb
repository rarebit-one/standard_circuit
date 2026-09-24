require "spec_helper"
require "postmark"

RSpec.describe StandardCircuit::AdapterErrors::Postmark do
  describe ".server_errors" do
    it "lists HttpServerError and TimeoutError" do
      expect(described_class.server_errors).to eq([ Postmark::HttpServerError, Postmark::TimeoutError ])
    end

    it "covers Postmark 5xx subclasses via HttpServerError" do
      error = Postmark::InternalServerError.new(500, "", {})
      expect(described_class.server_errors.any? { |klass| klass === error }).to be(true)
    end

    it "returns [] when the postmark gem isn't loaded" do
      hide_const("Postmark")
      expect(described_class.server_errors).to eq([])
    end
  end

  describe ".caller_errors" do
    it "lists ApiInputError and InvalidApiKeyError" do
      expect(described_class.caller_errors).to eq([ Postmark::ApiInputError, Postmark::InvalidApiKeyError ])
    end

    it "lists only subclasses of a tracked server error (why they must be skipped explicitly)" do
      expect(described_class.caller_errors).to all(be < Postmark::HttpServerError)
    end

    it "returns [] when the postmark gem isn't loaded" do
      hide_const("Postmark")
      expect(described_class.caller_errors).to eq([])
    end
  end
end
