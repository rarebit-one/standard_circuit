require "spec_helper"
require "standard_circuit/health_controller"

RSpec.describe StandardCircuit::HealthController do
  let(:instance) { described_class.new }

  describe "#show" do
    it "returns status 200 and renders the report when status is :ok" do
      allow(StandardCircuit).to receive(:health_report).and_return(
        status: :ok,
        circuits: [ { name: :stripe, color: "green", locked: false, criticality: :critical } ]
      )

      rendered = nil
      allow(instance).to receive(:render) { |**opts| rendered = opts }

      instance.show

      expect(rendered[:status]).to eq(:ok)
      expect(rendered[:json]).to include(status: :ok)
      expect(rendered[:json][:circuits]).to be_an(Array)
    end

    it "returns status 200 for :degraded (app can still serve traffic)" do
      allow(StandardCircuit).to receive(:health_report).and_return(status: :degraded, circuits: [])

      rendered = nil
      allow(instance).to receive(:render) { |**opts| rendered = opts }

      instance.show

      expect(rendered[:status]).to eq(:ok)
      expect(rendered[:json][:status]).to eq(:degraded)
    end

    it "returns status 503 (service_unavailable) when status is :critical" do
      allow(StandardCircuit).to receive(:health_report).and_return(
        status: :critical,
        circuits: [ { name: :payments, color: "red", locked: true, criticality: :critical } ]
      )

      rendered = nil
      allow(instance).to receive(:render) { |**opts| rendered = opts }

      instance.show

      expect(rendered[:status]).to eq(:service_unavailable)
      expect(rendered[:json][:status]).to eq(:critical)
    end
  end

  describe "inheritance" do
    it "inherits from ActionController::API so it sidesteps app filters" do
      expect(described_class.ancestors).to include(::ActionController::API)
    end
  end
end
