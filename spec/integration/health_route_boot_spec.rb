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
RSpec.describe "aggregate health route in a booted Rails app" do
  boot = nil

  before(:context) do # rubocop:disable RSpec/BeforeAfterAll
    script = File.expand_path("../support/health_route_boot_app.rb", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)
    raise "probe app failed to boot (#{status.exitstatus}):\n#{stdout}\n#{stderr}" unless status.success?

    boot = stdout.lines.filter_map { |line| line.chomp.split("=", 2) if line.include?("=") }.to_h
  end

  it "has isolate_namespace in effect" do
    expect(boot["engine_isolated"]).to eq("true")
  end

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

  # Documented consequences of isolation, asserted so they stay intentional.
  it "namespaces table names for any StandardCircuit model (the gem defines none)" do
    expect(boot["table_name_prefix"]).to eq("standard_circuit_")
  end

  it "leaves the main_app helper available inside the gem's controller" do
    expect(boot["main_app_helper"]).to eq("true")
  end
end
