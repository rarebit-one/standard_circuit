# Shim for ActiveStorage::Service::Configurator
#
# When storage.yml says `service: StandardCircuitS3`, ActiveStorage's
# Configurator calls:
#   require "active_storage/service/standard_circuit_s3_service"
#   const_get("StandardCircuitS3Service")
#
# This file's only purpose is to exist at that load path so the require
# succeeds. The actual implementation lives at
# lib/standard_circuit/active_storage/s3_service.rb so the gem's layout
# follows the StandardCircuit:: namespace convention.

require "standard_circuit/active_storage/s3_service"
