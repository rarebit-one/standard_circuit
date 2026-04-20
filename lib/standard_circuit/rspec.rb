require "standard_circuit"

RSpec.configure do |config|
  config.after(:each) do
    StandardCircuit.reset_force!
  end
end
