# What New agent shows under the address as the name or the address is typed:
# the address the agent will write from, or why it can't have it. Only the
# server knows which are taken. Nothing is kept: the address is fixed when the
# agent is made.
class Agents::AddressesController < ApplicationController
  def show
    @name = params[:name].to_s.squish
    @email_name = params[:email_name].presence
  end
end
