# Development only (the route exists nowhere else): sign in as a local person
# without an Ajent client, so the app can be tried on a laptop.
class DevelopmentSessionsController < ApplicationController
  allow_unauthenticated_access

  def create
    raise ActionController::RoutingError, "Not Found" unless Rails.env.development?
    start_session_for User.sign_in_from_oidc!(sub: "development", email: "developer@localhost", name: "Developer")
  end
end
