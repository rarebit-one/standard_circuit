require "active_storage"
require "active_storage/service"
require "active_storage/service/s3_service"

# NOTE: ActiveStorage's Configurator does
#   require "active_storage/service/standard_circuit_s3_service"
# when storage.yml has `service: StandardCircuitS3`. We ship a shim at
# lib/active_storage/service/standard_circuit_s3_service.rb that requires this
# file, so the conventional require path works.
module ActiveStorage
  class Service::StandardCircuitS3Service < Service::S3Service
    WRAPPED_METHODS = %i[
      upload
      download
      download_chunk
      delete
      delete_prefixed
      exist?
      compose
      update_metadata
    ].freeze

    WRAPPED_METHODS.each do |method_name|
      define_method(method_name) do |*args, **kwargs, &block|
        StandardCircuit.run(circuit_name) { super(*args, **kwargs, &block) }
      end
    end

    private

    def circuit_name
      :"s3_#{bucket.name}"
    end
  end
end

module StandardCircuit
  module ActiveStorage
    S3Service = ::ActiveStorage::Service::StandardCircuitS3Service
  end
end
