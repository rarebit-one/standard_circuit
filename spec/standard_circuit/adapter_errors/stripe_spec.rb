require "spec_helper"
require "stripe"

RSpec.describe StandardCircuit::AdapterErrors::Stripe do
  describe ".server_errors" do
    it "lists connection, rate-limit, and API (5xx) errors" do
      expect(described_class.server_errors).to eq(
        [ Stripe::APIConnectionError, Stripe::RateLimitError, Stripe::APIError ]
      )
    end

    it "returns [] when the stripe gem isn't loaded" do
      hide_const("Stripe")
      expect(described_class.server_errors).to eq([])
    end
  end

  describe ".caller_errors" do
    it "lists invalid-request, card, and authentication errors" do
      expect(described_class.caller_errors).to eq(
        [ Stripe::InvalidRequestError, Stripe::CardError, Stripe::AuthenticationError ]
      )
    end

    it "returns [] when the stripe gem isn't loaded" do
      hide_const("Stripe")
      expect(described_class.caller_errors).to eq([])
    end
  end

  it "keeps server and caller errors disjoint" do
    expect(described_class.server_errors & described_class.caller_errors).to be_empty
  end

  it "returns a fresh array each call" do
    described_class.server_errors << RuntimeError
    expect(described_class.server_errors).not_to include(RuntimeError)
  end
end
