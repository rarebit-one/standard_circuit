require "simplecov"
SimpleCov.start do
  enable_coverage :branch
  add_filter "/spec/"
end

# Load Rails::Railtie before standard_circuit so the conditional
# `class Railtie < ::Rails::Railtie` block in delivery_method.rb is
# evaluated on first require — avoids needing `load` in railtie_spec.rb.
# `action_mailer` is required first so its activesupport extensions
# (e.g. `delegate_missing_to`) are loaded before `rails/railtie` resolves.
require "action_mailer"
require "rails/railtie"
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
