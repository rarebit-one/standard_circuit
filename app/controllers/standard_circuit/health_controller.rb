module StandardCircuit
  # Health-check controller. Renders +StandardCircuit.health_report+ as JSON
  # and returns 503 when the rolled-up status is +:critical+ so upstream
  # orchestrators pull the instance out of rotation. :degraded and :ok both
  # return 200 — the app can still serve most traffic.
  #
  # Autoloaded by the engine (it lives under app/controllers), so a host only
  # draws the route — no `require` needed:
  #
  #   # config/routes.rb
  #   Rails.application.routes.draw do
  #     get "/health", to: "standard_circuit/health#show"
  #   end
  #
  # The pre-0.4 `require "standard_circuit/health_controller"` still works but
  # is deprecated (see lib/standard_circuit/health_controller.rb).
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
