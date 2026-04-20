require "active_storage"
require "active_storage/service"
require "active_storage/service/s3_service"

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
