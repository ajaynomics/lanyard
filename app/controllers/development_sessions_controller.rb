# Development only (the route exists nowhere else): sign in as a local person
# without an Ajent client, so the app can be tried on a laptop, in a browser
# or through the phone app's sign-in sheet (NativeSignIn).
class DevelopmentSessionsController < ApplicationController
  allow_unauthenticated_access

  def create
    raise ActionController::RoutingError, "Not Found" unless Rails.env.development?
    complete_sign_in User.sign_in!(sub: "development", email: "developer@localhost", name: "Developer"), email: "developer@localhost"
  end
end
