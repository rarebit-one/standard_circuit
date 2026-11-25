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

    it "wins last-declared lookup over a user `rescue_from StandardError` declared earlier" do
      shadowing_class = Class.new(ActionController::Base) do
        include StandardCircuit::ControllerSupport

        rescue_from StandardError do
          :user_handler
        end

        circuit_open_fallback html: -> { :gem_handler }
      end

      handlers = shadowing_class.rescue_handlers
      red_light_index = handlers.rindex { |h| h.first == "Stoplight::Error::RedLight" }
      standard_error_index = handlers.rindex { |h| h.first == "StandardError" }

      expect(red_light_index).to be > standard_error_index,
        "expected RedLight handler appended after the StandardError catch-all"
    end

    it "does not accumulate duplicate handlers when circuit_open_fallback is called multiple times" do
      controller_class.circuit_open_fallback(html: -> { :first })
      controller_class.circuit_open_fallback(html: -> { :second })

      red_light_count = controller_class.rescue_handlers.count { |h| h.first == "Stoplight::Error::RedLight" }
      expect(red_light_count).to eq(1)
    end
  end

  describe "#handle_circuit_open dispatching" do
    let(:instance) { controller_class.new }
    let(:red_light) do
      Stoplight::Error::RedLight.new("stripe", cool_off_time: 30, retry_after: nil)
    end

    let(:html_request) { double("req", format: double(json?: false), formats: [ Mime[:html] ]) }
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

  describe "content negotiation through a real request (0.8.1)" do
    def build_controller(parent)
      Class.new(parent) do
        include StandardCircuit::ControllerSupport

        circuit_open_fallback json: -> { render json: { error: "service_unavailable" }, status: :service_unavailable },
          html: -> { render plain: "html fallback", status: :service_unavailable }

        def show
          raise Stoplight::Error::RedLight.new("stripe", cool_off_time: 30, retry_after: nil)
        end
      end
    end

    def dispatch(controller, accept: nil, path: "/thing")
      env = Rack::MockRequest.env_for(path, "HTTP_ACCEPT" => accept)
      env.delete("HTTP_ACCEPT") if accept.nil?
      status, headers, body = controller.action(:show).call(env)
      text = +""
      body.each { |chunk| text << chunk }
      [ status, headers["content-type"].to_s, text, headers["retry-after"] ]
    end

    before { StandardCircuit.config.register(:stripe, cool_off_time: 30) }

    let(:base_controller) { build_controller(ActionController::Base) }
    let(:api_controller) { build_controller(ActionController::API) }

    {
      "Accept: application/json" => "application/json",
      "Accept: */*" => "*/*",
      "no Accept header" => nil,
      "Accept: text/plain" => "text/plain"
    }.each do |label, accept|
      it "answers an ActionController::API request with json: (#{label})" do
        status, content_type, body, retry_after = dispatch(api_controller, accept: accept)

        expect(status).to eq(503)
        expect(content_type).to start_with("application/json")
        expect(JSON.parse(body)).to eq("error" => "service_unavailable")
        expect(retry_after).to eq("30")
      end
    end

    it "answers an API controller with json: for a .json path too" do
      _, content_type, = dispatch(api_controller, path: "/thing.json")

      expect(content_type).to start_with("application/json")
    end

    it "keeps html: for a browser on an ActionController::Base controller" do
      _, content_type, body = dispatch(base_controller,
        accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")

      expect(content_type).to start_with("text/plain")
      expect(body).to eq("html fallback")
    end

    it "keeps html: on a Base controller for Accept: */* and for no Accept header (both accept HTML)" do
      expect(dispatch(base_controller, accept: "*/*")[2]).to eq("html fallback")
      expect(dispatch(base_controller, accept: nil)[2]).to eq("html fallback")
    end

    it "uses json: on a Base controller when the request asks for JSON" do
      _, content_type, = dispatch(base_controller, accept: "application/json")

      expect(content_type).to start_with("application/json")
    end

    it "uses json: on a Base controller when the request doesn't accept HTML" do
      _, content_type, = dispatch(base_controller, accept: "text/plain")

      expect(content_type).to start_with("application/json")
    end

    it "uses json: when the Accept header names only unregistered types" do
      _, content_type, = dispatch(base_controller, accept: "application/x-unregistered")

      expect(content_type).to start_with("application/json")
    end

    it "keeps stream: ahead of the API rule for a streaming controller that didn't ask for JSON" do
      streaming = Class.new(ActionController::API) do
        include StandardCircuit::ControllerSupport

        circuit_open_fallback json: -> { :json }, stream: ->(_response) { :stream }
      end
      instance = streaming.new
      allow(instance).to receive_messages(streaming_controller?: true, response: ActionDispatch::Response.new,
        request: double("req", format: double(json?: false), formats: [ Mime::ALL ]))

      expect(instance.send(:handle_circuit_open, Stoplight::Error::RedLight.new("stripe", cool_off_time: 30, retry_after: nil)))
        .to eq(:stream)
    end

    it "falls back to html: and then head when there is no json: lambda" do
      html_only = Class.new(ActionController::API) do
        include StandardCircuit::ControllerSupport

        def show
          raise Stoplight::Error::RedLight.new("stripe", cool_off_time: 30, retry_after: nil)
        end
      end

      status, _, body, retry_after = dispatch(html_only, accept: "*/*")
      expect(status).to eq(503)
      expect(body).to eq("")
      expect(retry_after).to eq("30")
    end
  end

  describe "the RedLight reaches the json:/html: lambdas (0.8)" do
    let(:instance) { controller_class.new }
    let(:red_light) { Stoplight::Error::RedLight.new("stripe", cool_off_time: 30, retry_after: nil) }

    before { allow(instance).to receive(:response).and_return(ActionDispatch::Response.new) }

    def dispatch(json:)
      allow(instance).to receive(:request).and_return(double("req", format: double(json?: json), formats: [ Mime[:html] ]))
      instance.send(:handle_circuit_open, red_light)
    end

    it "passes the error to a one-argument json lambda" do
      controller_class.circuit_open_fallback(json: ->(error) { [ :json, error.light_name ] })

      expect(dispatch(json: true)).to eq([ :json, "stripe" ])
    end

    it "passes the error to a one-argument html block, run in the controller" do
      controller_class.circuit_open_fallback(html: proc { |error| [ self.class, error ] })

      expect(dispatch(json: false)).to eq([ controller_class, red_light ])
    end

    it "passes the error to a lambda with optional or splat parameters" do
      controller_class.circuit_open_fallback(json: ->(*args) { args })

      expect(dispatch(json: true)).to eq([ red_light ])
    end

    it "still calls zero-arity lambdas and procs without arguments" do
      controller_class.circuit_open_fallback(json: -> { :json_ok }, html: proc { :html_ok })

      expect([ dispatch(json: true), dispatch(json: false) ]).to eq([ :json_ok, :html_ok ])
    end
  end

  describe "Retry-After (0.8)" do
    let(:instance) { controller_class.new }
    let(:response) { ActionDispatch::Response.new }

    before do
      allow(instance).to receive_messages(response: response,
        request: double("req", format: double(json?: false), formats: [ Mime[:html] ]))
      allow(instance).to receive(:head)
    end

    def retry_after_for(error)
      instance.send(:handle_circuit_open, error)
      response.headers["Retry-After"]
    end

    def red_light(name = "stripe", retry_after: nil)
      Stoplight::Error::RedLight.new(name, cool_off_time: 99, retry_after: retry_after)
    end

    it "counts down to the RedLight's recovery time, in whole seconds rounded up" do
      expect(retry_after_for(red_light(retry_after: Time.now + 12.3))).to eq("13")
    end

    it "is at least 1 when the recovery time has already passed" do
      expect(retry_after_for(red_light(retry_after: Time.now - 5))).to eq("1")
    end

    it "falls back to the circuit's cool_off_time when the light has no recovery time (locked or forced)" do
      StandardCircuit.config.register(:stripe, cool_off_time: 45)

      expect(retry_after_for(red_light)).to eq("45")
    end

    it "uses a prefix registration's cool_off_time" do
      StandardCircuit.config.register_prefix(:s3, cool_off_time: 20.5)

      expect(retry_after_for(red_light("s3_uploads"))).to eq("21")
    end

    it "is omitted when neither is known" do
      expect(retry_after_for(red_light("unregistered"))).to be_nil
    end

    it "is set on json, html and bare head responses alike" do
      StandardCircuit.config.register(:stripe, cool_off_time: 30)
      controller_class.circuit_open_fallback(json: -> { :json })

      allow(instance).to receive(:request).and_return(double("req", format: double(json?: true)))
      expect(retry_after_for(red_light)).to eq("30")
    end

    it "counts down a tripped breaker's cool-off, from stoplight's recovery time" do
      StandardCircuit.configure { |c| c.register(:ctrl_svc, threshold: 1, cool_off_time: 40, tracked_errors: [ IOError ]) }
      expect { StandardCircuit.run(:ctrl_svc) { raise IOError } }.to raise_error(IOError)
      error = begin
        StandardCircuit.run(:ctrl_svc) { :unreachable }
      rescue Stoplight::Error::RedLight => e
        e
      end

      expect(retry_after_for(error).to_i).to be_between(39, 40)
    end

    it "is set for a forced-open circuit reached through a real run" do
      StandardCircuit.configure { |c| c.register(:ctrl_svc, cool_off_time: 60) }
      error = StandardCircuit.force_open(:ctrl_svc) do
        StandardCircuit.run(:ctrl_svc) { :unreachable }
      rescue Stoplight::Error::RedLight => e
        e
      end

      expect(retry_after_for(error)).to eq("60")
    end
  end

  describe "circuit-open request metric" do
    let(:instance) { controller_class.new }
    let(:html_request) { double("req", format: double(json?: false), formats: [ Mime[:html] ]) }

    before do
      allow(::Sentry::Metrics).to receive(:count)
      allow(::Sentry::Metrics).to receive(:distribution)
      allow(instance).to receive(:request).and_return(html_request)
      controller_class.circuit_open_fallback(html: -> { @fallback_rendered = true })
    end

    def expect_single_circuit_open_count
      expect(::Sentry::Metrics).to have_received(:count)
        .with("external.request", value: 1, attributes: { service: "ctrl_svc", status: "circuit_open" })
        .exactly(1).time
    end

    def red_light_from
      yield
      raise "expected Stoplight::Error::RedLight"
    rescue Stoplight::Error::RedLight => e
      e
    end

    it "counts a tripped-circuit rejection exactly once when it reaches the controller" do
      StandardCircuit.configure { |c| c.register(:ctrl_svc, threshold: 1, tracked_errors: [ Errno::ECONNREFUSED ]) }
      expect { StandardCircuit.run(:ctrl_svc) { raise Errno::ECONNREFUSED } }.to raise_error(Errno::ECONNREFUSED)

      error = red_light_from { StandardCircuit.run(:ctrl_svc) { :unreachable } }

      expect(instance.rescue_with_handler(error)).to be(error)
      expect(instance.instance_variable_get(:@fallback_rendered)).to be(true)
      expect_single_circuit_open_count
    end

    it "counts a forced-open rejection exactly once when it reaches the controller" do
      StandardCircuit.configure { |c| c.register(:ctrl_svc) }

      error = StandardCircuit.force_open(:ctrl_svc) do
        red_light_from { StandardCircuit.run(:ctrl_svc) { :unreachable } }
      end

      expect(instance.rescue_with_handler(error)).to be(error)
      expect(instance.instance_variable_get(:@fallback_rendered)).to be(true)
      expect_single_circuit_open_count
    end
  end
end
