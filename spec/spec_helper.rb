require "standard_circuit"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.mock_with :rspec do |m|
    m.verify_partial_doubles = true
  end

  config.order = :random
  Kernel.srand config.seed

  config.before do
    StandardCircuit.reset!
    StandardCircuit.config.reset_registry!
    StandardCircuit.config.data_store = Stoplight::DataStore::Memory.new
  end
end
