require "spec_helper"
require "action_controller"
require "action_controller/base"
require "standard_circuit/controller_support"

RSpec.describe StandardCircuit::ControllerSupport do
  let(:controller_class) do
    Class.new(ActionController::Base) do
      include StandardCircuit::ControllerSupport
    end
  end

  describe "DSL" do
    it "stores the fallback config on the class" do
      controller_class.circuit_open_fallback(
        status: :service_unavailable,
        html: -> { :rendered_html },
        json: -> { :rendered_json }
      )

      expect(controller_class._circuit_open_fallback).to include(
        status: :service_unavailable,
        html: kind_of(Proc),
        json: kind_of(Proc)
      )
    end
  end

  describe "rescue_from wiring" do
    it "registers a rescue_from for Stoplight::Error::RedLight" do
      handlers = controller_class.rescue_handlers.map(&:first)
      expect(handlers).to include("Stoplight::Error::RedLight")
    end
  end

  describe "#handle_circuit_open dispatching" do
    let(:instance) { controller_class.new }
    let(:red_light) do
      Stoplight::Error::RedLight.new("stripe", cool_off_time: 30, retry_after: nil)
    end

    let(:html_request) { double("req", format: double(json?: false)) }
    let(:json_request) { double("req", format: double(json?: true)) }

    before do
      controller_class.circuit_open_fallback(
        html: -> { :html_handler_fired },
        json: -> { :json_handler_fired }
      )
    end

    it "dispatches to the json handler when the request is JSON" do
      allow(instance).to receive(:request).and_return(json_request)
      expect(instance.send(:handle_circuit_open, red_light)).to eq(:json_handler_fired)
    end

    it "dispatches to the html handler when the request is HTML" do
      allow(instance).to receive(:request).and_return(html_request)
      expect(instance.send(:handle_circuit_open, red_light)).to eq(:html_handler_fired)
    end

    it "falls back to head :service_unavailable when no handler matches" do
      controller_class.circuit_open_fallback(status: :gateway_timeout)
      allow(instance).to receive(:request).and_return(html_request)
      expect(instance).to receive(:head).with(:gateway_timeout)
      instance.send(:handle_circuit_open, red_light)
    end
  end
end
