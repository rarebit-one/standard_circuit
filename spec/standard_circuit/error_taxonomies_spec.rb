require "spec_helper"

RSpec.describe StandardCircuit::ErrorTaxonomies do
  describe described_class::Stripe do
    it "combines NetworkErrors.defaults with AdapterErrors::Stripe.server_errors" do
      expected = StandardCircuit::NetworkErrors.defaults +
        StandardCircuit::AdapterErrors::Stripe.server_errors
      expect(described_class.tracked).to eq(expected)
    end

    it "returns a fresh array each call (callers can mutate without leakage)" do
      first = described_class.tracked
      first << StandardError
      expect(described_class.tracked).not_to include(StandardError)
    end
  end

  describe described_class::Smtp do
    it "combines NetworkErrors.defaults with AdapterErrors::Smtp.server_errors" do
      expected = StandardCircuit::NetworkErrors.defaults +
        StandardCircuit::AdapterErrors::Smtp.server_errors
      expect(described_class.tracked).to eq(expected)
    end
  end

  describe described_class::Aws do
    it "combines NetworkErrors.defaults with AdapterErrors::Aws.server_errors" do
      expected = StandardCircuit::NetworkErrors.defaults +
        StandardCircuit::AdapterErrors::Aws.server_errors
      expect(described_class.tracked).to eq(expected)
    end
  end

  describe described_class::Faraday do
    it "combines NetworkErrors.defaults with AdapterErrors::Faraday.server_errors" do
      expected = StandardCircuit::NetworkErrors.defaults +
        StandardCircuit::AdapterErrors::Faraday.server_errors
      expect(described_class.tracked).to eq(expected)
    end
  end
end
