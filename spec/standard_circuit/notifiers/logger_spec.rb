require "spec_helper"
require "logger"

RSpec.describe StandardCircuit::Notifiers::Logger do
  let(:io) { StringIO.new }
  let(:logger) { ::Logger.new(io) }
  let(:light) { instance_double(Stoplight::Domain::Light, name: "stripe") }

  describe "#notify" do
    it "logs transitions with context" do
      described_class.new(logger).notify(light, "green", "red", StandardError.new("boom"))
      expect(io.string).to include("stripe", "green", "red", "StandardError", "boom")
    end

    it "logs at warn level when the new color is red" do
      described_class.new(logger).notify(light, "green", "red", StandardError.new("x"))
      expect(io.string).to include("WARN")
    end

    it "logs at info level on non-red transitions" do
      described_class.new(logger).notify(light, "yellow", "green", nil)
      expect(io.string).to include("INFO")
    end
  end
end
