require "spec_helper"
require "open3"

# `isolate_namespace StandardCircuit` (lib/standard_circuit/engine.rb) changes
# route, helper, and table-name scoping. Every consumer app routes the aggregate
# health tier straight at the gem's controller —
#
#   get "/health", to: "standard_circuit/health#show"
#
# — from the *application's* route set, so this boots a real Rails app and
# requests it end to end. If isolation ever starts swallowing or re-scoping that
# path, this fails loudly here instead of in five apps after a release.
module HealthRouteProbe
  SCRIPT = File.expand_path("../support/health_route_boot_app.rb", __dir__)

  # One subprocess boot per mode, shared by that mode's examples.
  def self.boot(mode)
    (@boots ||= {})[mode] ||= begin
      stdout, stderr, status = Open3.capture3({ "PROBE_MODE" => mode }, RbConfig.ruby, SCRIPT)
      raise "probe app (#{mode}) failed to boot (#{status.exitstatus}):\n#{stdout}\n#{stderr}" unless status.success?

      stdout.lines.filter_map { |line| line.chomp.split("=", 2) if line.include?("=") }.to_h
    end
  end
end

RSpec.describe "aggregate health route in a booted Rails app" do
  shared_examples "a working /health route" do
    it "routes GET /health to the gem's controller from the application route set" do
      expect(boot["recognized"]).to include("standard_circuit/health", "show")
    end

    it "answers 200 with the JSON health report" do
      expect(boot["status"]).to eq("200")
      expect(boot["content_type"]).to include("application/json")
      expect(JSON.parse(boot["body"])).to include(
        "status" => "ok",
        "circuits" => [ hash_including("name" => "stripe", "criticality" => "critical") ]
      )
    end
  end

  context "with no require (autoloaded by the engine)" do
    let(:boot) { HealthRouteProbe.boot("autoload") }

    it_behaves_like "a working /health route"

    it "leaves the controller to the autoloader until first use" do
      expect(boot["autoload_pending"]).to eq("true")
    end

    it "emits no deprecation" do
      expect(boot["deprecations"]).to eq("0")
    end

    it "has isolate_namespace in effect" do
      expect(boot["engine_isolated"]).to eq("true")
    end

    # Documented consequences of isolation, asserted so they stay intentional.
    it "namespaces table names for any StandardCircuit model (the gem defines none)" do
      expect(boot["table_name_prefix"]).to eq("standard_circuit_")
    end

    it "leaves the main_app helper available inside the gem's controller" do
      expect(boot["main_app_helper"]).to eq("true")
    end
  end

  context "with eager loading (production shape)" do
    let(:boot) { HealthRouteProbe.boot("eager") }

    it_behaves_like "a working /health route"

    it "eager-loads the controller at boot" do
      expect(boot["autoload_pending"]).to eq("false")
    end
  end

  context "with the pre-0.4 require at the top of routes.rb" do
    let(:boot) { HealthRouteProbe.boot("legacy_routes") }

    it_behaves_like "a working /health route"

    it "emits one deprecation through the app's deprecators" do
      expect(boot["deprecations"]).to eq("1")
    end
  end

  context "with the pre-0.4 require in an initializer (before autoloaders are set up)" do
    let(:boot) { HealthRouteProbe.boot("legacy_initializer") }

    it_behaves_like "a working /health route"
  end
end
