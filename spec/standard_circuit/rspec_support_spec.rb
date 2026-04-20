require "spec_helper"

# The require "standard_circuit/rspec" path registers an after(:each) that
# clears forced state. Loading spec_helper loads the gem; here we verify the
# support file can be required and installs the hook.
RSpec.describe "standard_circuit/rspec support file" do
  it "can be required and registers an after(:each) hook" do
    expect { require "standard_circuit/rspec" }.not_to raise_error

    StandardCircuit.configure do |c|
      c.register(:example, threshold: 2, cool_off_time: 10)
    end

    StandardCircuit.force_open(:example)
    expect { StandardCircuit.run(:example) { :never } }
      .to raise_error(Stoplight::Error::RedLight)
  end

  it "clears forced state between examples (runs after the previous example)" do
    StandardCircuit.configure do |c|
      c.register(:example, threshold: 2, cool_off_time: 10)
    end

    # If the previous example's force_open leaked, this would raise.
    expect(StandardCircuit.run(:example) { :ok }).to eq(:ok)
  end
end
