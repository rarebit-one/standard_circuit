# Boots a real (minimal) Rails application, draws the route the workspace
# health convention prescribes, and issues an actual request against it.
#
# Run as a subprocess by spec/integration/health_route_boot_spec.rb: booting a
# Rails::Application defines Rails.application / Rails.event, which would
# poison the sibling specs that exercise the pre-8.1 ActiveSupport::Notifications
# fallback via `hide_const("Rails")` under `config.order = :random`.
#
# Prints `key=value` lines for the spec to assert on.
require "rails"
require "action_controller/railtie"
require "rack/test"
require "standard_circuit"

class HealthRouteProbeApp < Rails::Application
  config.eager_load = false
  config.load_defaults 8.0
  config.secret_key_base = "x" * 64
  config.logger = Logger.new(IO::NULL)
  config.consider_all_requests_local = true
  config.hosts.clear
end

HealthRouteProbeApp.initialize!

# Host-side opt-in, exactly as the README and the install generator prescribe.
require "standard_circuit/health_controller"

HealthRouteProbeApp.routes.draw do
  # The convention-prescribed aggregate route (see
  # .claude/conventions/health-diagnostics-endpoints.md in the workspace root).
  get "/health", to: "standard_circuit/health#show"
  root to: proc { [ 200, { "content-type" => "text/plain" }, [ "root" ] ] }
end

StandardCircuit.configure do |c|
  c.register(:stripe, criticality: :critical)
end

include Rack::Test::Methods # rubocop:disable Style/MixinUsage

def app = HealthRouteProbeApp

get "/health"

puts "engine_isolated=#{StandardCircuit::Engine.isolated?}"
puts "recognized=#{HealthRouteProbeApp.routes.recognize_path('/health').inspect}"
puts "status=#{last_response.status}"
puts "content_type=#{last_response.headers['content-type']}"
puts "body=#{last_response.body}"
puts "table_name_prefix=#{StandardCircuit.table_name_prefix}"
puts "main_app_helper=#{StandardCircuit::HealthController.new.respond_to?(:main_app)}"
