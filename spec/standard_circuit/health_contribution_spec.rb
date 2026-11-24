require "spec_helper"

# The `ActiveSupport.on_load(:standard_health)` hook in health_contribution.rb,
# against stand-ins for the two facades standard_health hands it. The gem is
# not in this bundle on purpose: neither gem may require the other.
RSpec.describe "standard_health contribution" do
  # standard_health >= 0.10: has contribute_dependencies.
  let(:current_facade) do
    Class.new do
      attr_reader :readers

      def initialize = @readers = {}
      def contribute_check(*) = nil
      def contribute_env_vars(*) = nil
      def contribute_dependencies(source, &reader) = @readers[source] = reader
    end.new
  end

  # standard_health 0.9: the same facade without it.
  let(:legacy_facade) do
    Class.new do
      def contribute_check(*) = raise("standard_circuit must not contribute checks")
      def contribute_env_vars(*) = raise("standard_circuit must not contribute env vars")
    end.new
  end

  before { StandardCircuit.configure { |c| c.register(:stripe, criticality: :critical) } }

  it "contributes a reader that returns StandardCircuit.health_rows on each call" do
    ActiveSupport.run_load_hooks(:standard_health, current_facade)

    reader = current_facade.readers.fetch(:standard_circuit)
    expect(reader.call).to eq(StandardCircuit.health_rows)

    StandardCircuit.dependency(:stripe).lock_open!
    expect(reader.call.first).to include(name: "stripe", status: :unavailable)
  end

  it "contributes nothing to standard_health 0.9, which keeps folding health_report in" do
    expect { ActiveSupport.run_load_hooks(:standard_health, legacy_facade) }.not_to raise_error
  end

  it "loads without standard_health (the gem has no dependency on it)" do
    expect(Gem.loaded_specs).not_to have_key("standard_health")
    expect(defined?(StandardHealth)).to be_nil
  end
end
