require "spec_helper"
require "standard_circuit/active_storage/s3_service"

RSpec.describe ActiveStorage::Service::StandardCircuitS3Service do
  let(:bucket) { instance_double(Aws::S3::Bucket, name: "user-content") }
  let(:service) { described_class.allocate }

  before do
    service.instance_variable_set(:@bucket, bucket)
    StandardCircuit.configure do |c|
      c.register_prefix(:s3, threshold: 3, cool_off_time: 30,
                        tracked_errors: [ Net::OpenTimeout ])
    end
  end

  describe "wrapped methods" do
    described_class::WRAPPED_METHODS.each do |method_name|
      it "wraps ##{method_name} in a :s3_<bucket> circuit" do
        captured_circuit = nil
        allow(StandardCircuit).to receive(:run) do |circuit, &_block|
          captured_circuit = circuit
          :stubbed
        end

        service.send(method_name)
        expect(captured_circuit).to eq(:"s3_user-content")
      end
    end
  end

  describe "unwrapped methods" do
    %i[url url_for_direct_upload public_url].each do |method_name|
      it "does not wrap ##{method_name}" do
        expect(StandardCircuit).not_to receive(:run)
        # method_defined? checks public; private_method_defined? covers the rest
        defined_here = described_class.instance_method(method_name)
        inherited_from = defined_here.owner
        expect(inherited_from).not_to eq(described_class)
      end
    end
  end

  describe "per-bucket keying" do
    it "derives the circuit name from bucket.name, not storage.yml service key" do
      other_bucket = instance_double(Aws::S3::Bucket, name: "system-assets")
      other_service = described_class.allocate
      other_service.instance_variable_set(:@bucket, other_bucket)

      captured = []
      allow(StandardCircuit).to receive(:run) do |circuit, &_block|
        captured << circuit
      end

      service.upload
      other_service.upload
      expect(captured).to eq([ :"s3_user-content", :"s3_system-assets" ])
    end
  end
end
