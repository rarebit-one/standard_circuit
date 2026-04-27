require "spec_helper"

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
end
