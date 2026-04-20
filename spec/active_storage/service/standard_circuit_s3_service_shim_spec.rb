require "spec_helper"

# Verifies the shim that ActiveStorage's Configurator relies on.
# When storage.yml says `service: StandardCircuitS3`, ActiveStorage's
# Configurator calls `require "active_storage/service/standard_circuit_s3_service"`
# — that path must be requirable from the gem's load path, not from the
# StandardCircuit::ActiveStorage namespace where our code lives.
RSpec.describe "active_storage/service/standard_circuit_s3_service shim" do
  it "is requirable via the path ActiveStorage's Configurator expects" do
    expect { require "active_storage/service/standard_circuit_s3_service" }
      .not_to raise_error
  end

  it "defines the ActiveStorage::Service::StandardCircuitS3Service class" do
    require "active_storage/service/standard_circuit_s3_service"
    expect(ActiveStorage::Service::StandardCircuitS3Service).to be_a(Class)
    expect(ActiveStorage::Service::StandardCircuitS3Service.superclass)
      .to eq(ActiveStorage::Service::S3Service)
  end
end
