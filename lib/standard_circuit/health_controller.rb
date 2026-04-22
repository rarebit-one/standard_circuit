require "action_controller"

module StandardCircuit
  # Opt-in health-check controller. Renders +StandardCircuit.health_report+ as
  # JSON and returns 503 when the rolled-up status is +:critical+ so upstream
  # orchestrators pull the instance out of rotation. :degraded and :ok both
  # return 200 — the app can still serve most traffic.
  #
  # This controller is not auto-loaded. Consumers opt in:
  #
  #   # config/routes.rb
  #   require "standard_circuit/health_controller"
  #
  #   Rails.application.routes.draw do
  #     get "/health", to: "standard_circuit/health#show"
  #   end
  #
  # Inherits from +ActionController::API+ to sidestep any ApplicationController
  # filters (authentication, bootstrap redirects, etc.) — health probes must be
  # callable anonymously from load balancers and uptime monitors.
  class HealthController < ::ActionController::API
    def show
      report = StandardCircuit.health_report
      http_status = report[:status] == :critical ? :service_unavailable : :ok
      render json: report, status: http_status
    end
  end
end
