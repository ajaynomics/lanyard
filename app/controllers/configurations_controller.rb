# The path configuration a Hotwire Native app reads at launch, before anyone
# signs in (PathConfiguration): rules, nothing about anyone.
class ConfigurationsController < ApplicationController
  allow_unauthenticated_access

  def show
    expires_in 1.hour, public: true
    render json: PathConfiguration.fetch(params[:id])
  end
end
